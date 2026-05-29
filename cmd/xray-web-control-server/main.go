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
	Queue        []Command
}

type Server struct {
	mu           sync.Mutex
	routers      map[string]*Router
	agentToken   string
	webUser      string
	webPassword  string
	sessionSecret string
}

func env(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return def
}

func main() {
	listen := flag.String("listen", env("WEB_LISTEN", "127.0.0.1:18091"), "listen address")
	flag.Parse()

	s := &Server{
		routers:      map[string]*Router{},
		agentToken:   env("AGENT_TOKEN", "change-me-agent-token"),
		webUser:      env("WEB_USER", "admin"),
		webPassword:  env("WEB_PASSWORD", "admin"),
		sessionSecret: env("WEB_SESSION_SECRET", randomHex(32)),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", s.requireWeb(s.dashboard))
	mux.HandleFunc("/login", s.login)
	mux.HandleFunc("/logout", s.logout)
	mux.HandleFunc("/router/", s.requireWeb(s.routerPage))
	mux.HandleFunc("/api/web/routers/", s.requireWeb(s.webRouterAPI))
	mux.HandleFunc("/api/agent/heartbeat", s.requireAgent(s.agentHeartbeat))
	mux.HandleFunc("/api/agent/poll", s.requireAgent(s.agentPoll))
	mux.HandleFunc("/api/agent/result", s.requireAgent(s.agentResult))

	log.Printf("xray-web-control-server listening on %s", *listen)
	log.Fatal(http.ListenAndServe(*listen, securityHeaders(mux)))
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
		user := r.Form.Get("user")
		pass := r.Form.Get("password")
		if subtle.ConstantTimeCompare([]byte(user), []byte(s.webUser)) == 1 && subtle.ConstantTimeCompare([]byte(pass), []byte(s.webPassword)) == 1 {
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
	list := make([]*Router, 0, len(s.routers))
	for _, router := range s.routers {
		copy := *router
		list = append(list, &copy)
	}
	s.mu.Unlock()
	sort.Slice(list, func(i, j int) bool { return list[i].Name < list[j].Name })
	dashboardTpl.Execute(w, map[string]any{"Routers": list, "Now": time.Now()})
}

func (s *Server) routerPage(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimPrefix(r.URL.Path, "/router/")
	s.mu.Lock()
	r, ok := s.routers[id]
	var copy Router
	if ok { copy = *r }
	s.mu.Unlock()
	if !ok { http.NotFound(w, r); return }
	routerTpl.Execute(w, map[string]any{"Router": copy, "Now": time.Now(), "Actions": defaultActions()})
}

func defaultActions() []string {
	return []string{"status", "source_status", "update_subscription", "update_scripts", "update_agent", "doctor", "recover_status", "recover_run", "recover_enable", "recover_disable", "history", "watchdog_log", "recovery_log", "agent_result_log", "switch_primary", "switch_backup", "reboot"}
}

func (s *Server) webRouterAPI(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/api/web/routers/"), "/")
	if len(parts) != 2 || parts[1] != "command" || r.Method != http.MethodPost { http.NotFound(w, r); return }
	id := parts[0]
	if err := r.ParseForm(); err != nil { http.Error(w, err.Error(), 400); return }
	action := strings.TrimSpace(r.Form.Get("action"))
	if action == "" { http.Error(w, "action required", 400); return }
	cmd := Command{ID: fmt.Sprintf("web-%d", time.Now().UnixNano()), Action: action, Slot: r.Form.Get("slot"), Selector: r.Form.Get("selector"), Source: r.Form.Get("source")}
	s.mu.Lock()
	router, ok := s.routers[id]
	if !ok { router = &Router{ID: id, Name: id}; s.routers[id] = router }
	router.Queue = append(router.Queue, cmd)
	s.mu.Unlock()
	http.Redirect(w, r, "/router/"+id, http.StatusFound)
}

func (s *Server) agentHeartbeat(w http.ResponseWriter, r *http.Request) {
	var hb Heartbeat
	if err := json.NewDecoder(r.Body).Decode(&hb); err != nil { http.Error(w, err.Error(), 400); return }
	if hb.RouterID == "" { http.Error(w, "router_id required", 400); return }
	s.mu.Lock()
	router := s.routers[hb.RouterID]
	if router == nil { router = &Router{ID: hb.RouterID}; s.routers[hb.RouterID] = router }
	router.Name = firstNonEmpty(hb.RouterName, hb.RouterID)
	router.AgentVersion = hb.AgentVersion
	router.Arch = hb.Arch
	router.Status = hb.Status
	router.Summary = hb.Summary
	router.Capabilities = hb.Capabilities
	router.LastSeen = time.Now()
	s.mu.Unlock()
	writeJSON(w, map[string]bool{"ok": true})
}

func (s *Server) agentPoll(w http.ResponseWriter, r *http.Request) {
	var hb Heartbeat
	if err := json.NewDecoder(r.Body).Decode(&hb); err != nil { http.Error(w, err.Error(), 400); return }
	if hb.RouterID == "" { http.Error(w, "router_id required", 400); return }
	s.mu.Lock()
	router := s.routers[hb.RouterID]
	if router == nil { router = &Router{ID: hb.RouterID, Name: firstNonEmpty(hb.RouterName, hb.RouterID)}; s.routers[hb.RouterID] = router }
	router.Name = firstNonEmpty(hb.RouterName, router.Name)
	router.AgentVersion = hb.AgentVersion
	router.Arch = hb.Arch
	router.Status = hb.Status
	router.Summary = hb.Summary
	router.Capabilities = hb.Capabilities
	router.LastSeen = time.Now()
	var cmd *Command
	if len(router.Queue) > 0 { c := router.Queue[0]; router.Queue = router.Queue[1:]; cmd = &c }
	s.mu.Unlock()
	writeJSON(w, PollResponse{Command: cmd})
}

func (s *Server) agentResult(w http.ResponseWriter, r *http.Request) {
	var res Result
	if err := json.NewDecoder(r.Body).Decode(&res); err != nil { http.Error(w, err.Error(), 400); return }
	if res.RouterID == "" { http.Error(w, "router_id required", 400); return }
	s.mu.Lock()
	router := s.routers[res.RouterID]
	if router == nil { router = &Router{ID: res.RouterID, Name: res.RouterID}; s.routers[res.RouterID] = router }
	router.LastResult = res
	router.LastSeen = time.Now()
	s.mu.Unlock()
	writeJSON(w, map[string]bool{"ok": true})
}

func firstNonEmpty(v ...string) string { for _, s := range v { if strings.TrimSpace(s) != "" { return s } }; return "" }
func writeJSON(w http.ResponseWriter, v any) { w.Header().Set("Content-Type", "application/json"); json.NewEncoder(w).Encode(v) }

func renderLogin(w http.ResponseWriter, err string) { loginTpl.Execute(w, map[string]string{"Error": err}) }

var loginTpl = template.Must(template.New("login").Parse(`<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>Xray Web Login</title><style>{{template "css"}}</style></head><body><main class="login"><h1>Xray Web Control</h1>{{if .Error}}<div class="err">{{.Error}}</div>{{end}}<form method="post"><label>Login<input name="user" autocomplete="username"></label><label>Password<input name="password" type="password" autocomplete="current-password"></label><button>Sign in</button></form></main></body></html>{{define "css"}}` + css + `{{end}}`))

var dashboardTpl = template.Must(template.New("dash").Funcs(template.FuncMap{"since": func(t time.Time) string { if t.IsZero(){return "never"}; return time.Since(t).Round(time.Second).String() }, "online": func(t time.Time) bool { return !t.IsZero() && time.Since(t) < 45*time.Second }}).Parse(`<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>Xray Web Control</title><style>{{template "css"}}</style></head><body><header><h1>Routers</h1><a href="/logout">logout</a></header><main><section class="grid">{{range .Routers}}<a class="card" href="/router/{{.ID}}"><div class="row"><strong>{{.Name}}</strong>{{if online .LastSeen}}<span class="ok">online</span>{{else}}<span class="bad">offline</span>{{end}}</div><p>{{.ID}}</p><p>{{.AgentVersion}} · {{.Arch}}</p><p>{{.Summary}}</p><small>heartbeat: {{since .LastSeen}} ago</small></a>{{else}}<p>No routers yet. Install xray-web-agent on a test router.</p>{{end}}</section></main></body></html>{{define "css"}}` + css + `{{end}}`))

var routerTpl = template.Must(template.New("router").Funcs(template.FuncMap{"since": func(t time.Time) string { if t.IsZero(){return "never"}; return time.Since(t).Round(time.Second).String() }}).Parse(`<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>{{.Router.Name}}</title><style>{{template "css"}}</style></head><body><header><h1>{{.Router.Name}}</h1><a href="/">dashboard</a></header><main><section class="card"><p><b>ID:</b> {{.Router.ID}}</p><p><b>Version:</b> {{.Router.AgentVersion}}</p><p><b>Arch:</b> {{.Router.Arch}}</p><p><b>Status:</b> {{.Router.Status}}</p><p><b>Summary:</b> {{.Router.Summary}}</p><p><b>Heartbeat:</b> {{since .Router.LastSeen}} ago</p></section><section class="card"><h2>Commands</h2><div class="actions">{{range .Actions}}<form method="post" action="/api/web/routers/{{$.Router.ID}}/command"><input type="hidden" name="action" value="{{.}}"><button>{{.}}</button></form>{{end}}</div><details><summary>Custom command</summary><form method="post" action="/api/web/routers/{{.Router.ID}}/command"><input name="action" placeholder="action"><input name="slot" placeholder="slot"><input name="selector" placeholder="selector"><textarea name="source" placeholder="source / payload"></textarea><button>Send</button></form></details></section><section class="card"><h2>Last result</h2><p><b>Command:</b> {{.Router.LastResult.CommandID}}</p><p><b>OK:</b> {{.Router.LastResult.OK}}</p><pre>{{.Router.LastResult.Output}}</pre></section></main></body></html>{{define "css"}}` + css + `{{end}}`))

const css = `body{margin:0;font:15px system-ui,-apple-system,Segoe UI,sans-serif;background:#0b1020;color:#e8eefc}header{display:flex;justify-content:space-between;align-items:center;padding:18px 24px;background:#111a33;border-bottom:1px solid #263354}main{padding:24px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:16px}.card{display:block;background:#141f3d;border:1px solid #2a3a66;border-radius:16px;padding:18px;color:#e8eefc;text-decoration:none;box-shadow:0 8px 24px #0005}.row{display:flex;justify-content:space-between;gap:12px}.ok{color:#54e38e}.bad,.err{color:#ff6978}.login{max-width:380px;margin:10vh auto;background:#141f3d;border:1px solid #2a3a66;border-radius:18px;padding:24px}label{display:block;margin:14px 0}input,textarea{width:100%;box-sizing:border-box;background:#0b1020;color:#e8eefc;border:1px solid #334677;border-radius:10px;padding:10px}button{background:#4f7cff;color:white;border:0;border-radius:10px;padding:10px 14px;cursor:pointer}button:hover{filter:brightness(1.1)}.actions{display:flex;flex-wrap:wrap;gap:8px}pre{white-space:pre-wrap;background:#0b1020;border-radius:12px;padding:12px;max-height:420px;overflow:auto}`
