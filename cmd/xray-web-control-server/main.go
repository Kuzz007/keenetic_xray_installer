package main

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

const serverVersion = "0.1.0-web-experimental"

type Command struct {
	ID       string `json:"id"`
	Action   string `json:"action"`
	Slot     string `json:"slot,omitempty"`
	Selector string `json:"selector,omitempty"`
	Source   string `json:"source,omitempty"`
}

type PollResponse struct {
	Command *Command `json:"command,omitempty"`
}

type Heartbeat struct {
	RouterID     string   `json:"router_id"`
	RouterName   string   `json:"router_name"`
	AgentVersion string   `json:"agent_version"`
	Arch         string   `json:"arch"`
	Status       string   `json:"status"`
	Capabilities []string `json:"capabilities"`
	Summary      string   `json:"summary"`
}

type Result struct {
	RouterID  string `json:"router_id"`
	CommandID string `json:"command_id"`
	OK        bool   `json:"ok"`
	Output    string `json:"output"`
}

type Router struct {
	ID           string
	Name         string
	AgentVersion string
	Arch         string
	Status       string
	Summary      string
	Capabilities []string
	LastSeen     time.Time
	LastResult   Result
	LastResultAt time.Time
	Queue        []Command
	History      []Result
}

type Server struct {
	mu            sync.Mutex
	routers       map[string]*Router
	agentToken    string
	webUser       string
	webPassword   string
	sessionSecret string
}

func main() {
	listen := flag.String("listen", env("WEB_LISTEN", "127.0.0.1:18091"), "listen address")
	flag.Parse()

	s := &Server{
		routers:       map[string]*Router{},
		agentToken:    env("AGENT_TOKEN", "change-me-agent-token"),
		webUser:       env("WEB_USER", "admin"),
		webPassword:   env("WEB_PASSWORD", "admin"),
		sessionSecret: env("WEB_SESSION_SECRET", randomHex(32)),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/login", s.login)
	mux.HandleFunc("/logout", s.logout)
	mux.HandleFunc("/", s.requireWeb(s.dashboard))
	mux.HandleFunc("/router/", s.requireWeb(s.routerPage))
	mux.HandleFunc("/api/web/routers/", s.requireWeb(s.webRouterAPI))
	mux.HandleFunc("/api/agent/heartbeat", s.requireAgent(s.agentHeartbeat))
	mux.HandleFunc("/api/agent/poll", s.requireAgent(s.agentPoll))
	mux.HandleFunc("/api/agent/result", s.requireAgent(s.agentResult))

	log.Printf("xray-web-control-server %s listening on %s", serverVersion, *listen)
	log.Fatal(http.ListenAndServe(*listen, securityHeaders(mux)))
}

func env(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return def
}

func randomHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return fmt.Sprintf("fallback-%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(b)
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		next.ServeHTTP(w, r)
	})
}

func (s *Server) requireAgent(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		got := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if subtle.ConstantTimeCompare([]byte(got), []byte(s.agentToken)) != 1 {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

func (s *Server) requireWeb(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		c, err := r.Cookie("xray_web_session")
		if err != nil || c.Value != s.sessionValue() {
			http.Redirect(w, r, "/login", http.StatusFound)
			return
		}
		next(w, r)
	}
}

func (s *Server) sessionValue() string { return "ok-" + s.sessionSecret }

func (s *Server) login(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPost {
		_ = r.ParseForm()
		if subtle.ConstantTimeCompare([]byte(r.Form.Get("user")), []byte(s.webUser)) == 1 && subtle.ConstantTimeCompare([]byte(r.Form.Get("password")), []byte(s.webPassword)) == 1 {
			http.SetCookie(w, &http.Cookie{Name: "xray_web_session", Value: s.sessionValue(), Path: "/", HttpOnly: true, SameSite: http.SameSiteLaxMode, Secure: r.TLS != nil})
			http.Redirect(w, r, "/", http.StatusFound)
			return
		}
		renderLogin(w, "Invalid login or password")
		return
	}
	renderLogin(w, "")
}

func (s *Server) logout(w http.ResponseWriter, r *http.Request) {
	http.SetCookie(w, &http.Cookie{Name: "xray_web_session", Value: "", Path: "/", MaxAge: -1})
	http.Redirect(w, r, "/login", http.StatusFound)
}

func (s *Server) dashboard(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	list := make([]Router, 0, len(s.routers))
	for _, router := range s.routers {
		list = append(list, *router)
	}
	s.mu.Unlock()
	sort.Slice(list, func(i, j int) bool { return list[i].Name < list[j].Name })
	render(w, dashboardTpl, map[string]any{"Routers": list, "Version": serverVersion})
}

func (s *Server) routerPage(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimPrefix(r.URL.Path, "/router/")
	s.mu.Lock()
	router, ok := s.routers[id]
	var copy Router
	if ok {
		copy = *router
	}
	s.mu.Unlock()
	if !ok {
		http.NotFound(w, r)
		return
	}
	render(w, routerTpl, map[string]any{"Router": copy, "Actions": defaultActions()})
}

func defaultActions() []string {
	return []string{"status", "source_status", "update_subscription", "update_scripts", "update_agent", "doctor", "recover_status", "recover_run", "recover_enable", "recover_disable", "history", "watchdog_log", "recovery_log", "agent_result_log", "switch_primary", "switch_backup", "reboot"}
}

func (s *Server) webRouterAPI(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/api/web/routers/"), "/")
	if len(parts) != 2 || parts[1] != "command" || r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	id := parts[0]
	if err := r.ParseForm(); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	action := strings.TrimSpace(r.Form.Get("action"))
	if action == "" {
		http.Error(w, "action required", http.StatusBadRequest)
		return
	}
	cmd := Command{ID: fmt.Sprintf("web-%d", time.Now().UnixNano()), Action: action, Slot: r.Form.Get("slot"), Selector: r.Form.Get("selector"), Source: r.Form.Get("source")}
	s.mu.Lock()
	router := s.ensureRouterLocked(id, id)
	router.Queue = append(router.Queue, cmd)
	s.mu.Unlock()
	http.Redirect(w, r, "/router/"+id, http.StatusFound)
}

func (s *Server) agentHeartbeat(w http.ResponseWriter, r *http.Request) {
	var hb Heartbeat
	if err := json.NewDecoder(r.Body).Decode(&hb); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if hb.RouterID == "" {
		http.Error(w, "router_id required", http.StatusBadRequest)
		return
	}
	s.mu.Lock()
	router := s.ensureRouterLocked(hb.RouterID, firstNonEmpty(hb.RouterName, hb.RouterID))
	applyHeartbeat(router, hb)
	s.mu.Unlock()
	writeJSON(w, map[string]bool{"ok": true})
}

func (s *Server) agentPoll(w http.ResponseWriter, r *http.Request) {
	var hb Heartbeat
	if err := json.NewDecoder(r.Body).Decode(&hb); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if hb.RouterID == "" {
		http.Error(w, "router_id required", http.StatusBadRequest)
		return
	}
	s.mu.Lock()
	router := s.ensureRouterLocked(hb.RouterID, firstNonEmpty(hb.RouterName, hb.RouterID))
	applyHeartbeat(router, hb)
	var cmd *Command
	if len(router.Queue) > 0 {
		c := router.Queue[0]
		router.Queue = router.Queue[1:]
		cmd = &c
	}
	s.mu.Unlock()
	writeJSON(w, PollResponse{Command: cmd})
}

func (s *Server) agentResult(w http.ResponseWriter, r *http.Request) {
	var res Result
	if err := json.NewDecoder(r.Body).Decode(&res); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if res.RouterID == "" {
		http.Error(w, "router_id required", http.StatusBadRequest)
		return
	}
	s.mu.Lock()
	router := s.ensureRouterLocked(res.RouterID, res.RouterID)
	router.LastResult = res
	router.LastResultAt = time.Now()
	router.LastSeen = time.Now()
	router.History = append([]Result{res}, router.History...)
	if len(router.History) > 20 {
		router.History = router.History[:20]
	}
	s.mu.Unlock()
	writeJSON(w, map[string]bool{"ok": true})
}

func (s *Server) ensureRouterLocked(id, name string) *Router {
	if router := s.routers[id]; router != nil {
		return router
	}
	router := &Router{ID: id, Name: firstNonEmpty(name, id)}
	s.routers[id] = router
	return router
}

func applyHeartbeat(router *Router, hb Heartbeat) {
	router.Name = firstNonEmpty(hb.RouterName, router.Name, hb.RouterID)
	router.AgentVersion = hb.AgentVersion
	router.Arch = hb.Arch
	router.Status = hb.Status
	router.Summary = hb.Summary
	router.Capabilities = hb.Capabilities
	router.LastSeen = time.Now()
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func renderLogin(w http.ResponseWriter, msg string) { render(w, loginTpl, map[string]string{"Error": msg}) }

func render(w http.ResponseWriter, tpl string, data any) {
	t := template.Must(template.New("page").Funcs(template.FuncMap{"online": online, "ago": ago}).Parse(tpl))
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := t.Execute(w, data); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

func online(t time.Time) bool { return !t.IsZero() && time.Since(t) < 45*time.Second }
func ago(t time.Time) string {
	if t.IsZero() {
		return "never"
	}
	return time.Since(t).Round(time.Second).String() + " ago"
}

const css = `<style>
body{font-family:system-ui,-apple-system,Segoe UI,sans-serif;background:#0b1020;color:#e7eaf3;margin:0}a{color:#8ab4ff}.wrap{max-width:1180px;margin:0 auto;padding:24px}.top{display:flex;justify-content:space-between;align-items:center}.card{background:#121a33;border:1px solid #26345f;border-radius:16px;padding:16px;margin:12px 0;box-shadow:0 8px 28px #0004}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:12px}.muted{color:#98a2bd}.ok{color:#5ee38a}.bad{color:#ff7b7b}.btn,button{background:#2b65ff;color:#fff;border:0;border-radius:10px;padding:9px 12px;text-decoration:none;cursor:pointer}select,input,textarea{background:#0b1020;color:#e7eaf3;border:1px solid #34456f;border-radius:8px;padding:8px}pre{white-space:pre-wrap;background:#080c18;border-radius:12px;padding:12px;overflow:auto}.row{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
</style>`

const loginTpl = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Xray Web Login</title>` + css + `</head><body><div class="wrap"><div class="card" style="max-width:420px;margin:12vh auto"><h1>Xray Web Control</h1>{{if .Error}}<p class="bad">{{.Error}}</p>{{end}}<form method="post"><p><input name="user" placeholder="Login" autocomplete="username" style="width:100%"></p><p><input name="password" type="password" placeholder="Password" autocomplete="current-password" style="width:100%"></p><button>Login</button></form></div></div></body></html>`

const dashboardTpl = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Xray Web Control</title>` + css + `</head><body><div class="wrap"><div class="top"><h1>Xray Web Control <span class="muted">{{.Version}}</span></h1><a class="btn" href="/logout">Logout</a></div><div class="grid">{{range .Routers}}<div class="card"><h2><a href="/router/{{.ID}}">{{.Name}}</a></h2><p>{{if online .LastSeen}}<b class="ok">online</b>{{else}}<b class="bad">offline</b>{{end}} <span class="muted">{{ago .LastSeen}}</span></p><p>{{.AgentVersion}} · {{.Arch}}</p><p class="muted">{{.Summary}}</p>{{if .LastResult.CommandID}}<p>Last: {{if .LastResult.OK}}<span class="ok">OK</span>{{else}}<span class="bad">FAIL</span>{{end}} {{.LastResult.CommandID}}</p>{{end}}</div>{{else}}<div class="card"><h2>No routers yet</h2><p class="muted">Install xray-web-agent on a test router.</p></div>{{end}}</div></div></body></html>`

const routerTpl = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{{.Router.Name}}</title>` + css + `</head><body><div class="wrap"><div class="top"><h1>{{.Router.Name}}</h1><a class="btn" href="/">Dashboard</a></div><div class="card"><p>ID: {{.Router.ID}}</p><p>{{if online .Router.LastSeen}}<b class="ok">online</b>{{else}}<b class="bad">offline</b>{{end}} <span class="muted">{{ago .Router.LastSeen}}</span></p><p>Version: {{.Router.AgentVersion}} · {{.Router.Arch}}</p><p>Status: {{.Router.Status}}</p><p class="muted">{{.Router.Summary}}</p></div><div class="card"><h2>Command</h2><form class="row" method="post" action="/api/web/routers/{{.Router.ID}}/command"><select name="action">{{range .Actions}}<option value="{{.}}">{{.}}</option>{{end}}</select><input name="slot" placeholder="slot"><input name="selector" placeholder="selector"><textarea name="source" placeholder="source / payload"></textarea><button>Send</button></form></div><div class="card"><h2>Last result</h2>{{if .Router.LastResult.CommandID}}<p>{{if .Router.LastResult.OK}}<span class="ok">OK</span>{{else}}<span class="bad">FAIL</span>{{end}} {{.Router.LastResult.CommandID}} <span class="muted">{{ago .Router.LastResultAt}}</span></p><pre>{{.Router.LastResult.Output}}</pre>{{else}}<p class="muted">No result yet.</p>{{end}}</div><div class="card"><h2>History</h2>{{range .Router.History}}<p>{{if .OK}}<span class="ok">OK</span>{{else}}<span class="bad">FAIL</span>{{end}} {{.CommandID}}</p>{{else}}<p class="muted">Empty.</p>{{end}}</div></div></body></html>`
