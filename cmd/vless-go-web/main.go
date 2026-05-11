package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"html/template"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"
)

const (
	defaultListen = "0.0.0.0:18088"
	tokenPath     = "/opt/etc/xray/vless-go-web.token"
)

type action struct {
	ID          string
	Label       string
	Description string
	Command     []string
	Timeout     time.Duration
	Group       string
	Danger      bool
}

type pageData struct {
	Listen          string
	Token           string
	Status          string
	Output          string
	PrimarySelector string
	BackupSelector  string
	Recovery        string
	Active          string
	PrimaryState    string
	BackupState     string
	WatchdogState   string
	HealthState     string
	Actions         []action
}

var actions = []action{
	{ID: "status", Label: "Обновить статус", Description: "Показать статус failover", Command: []string{"/opt/bin/vless-go-failover", "status"}, Timeout: 10 * time.Second, Group: "overview"},
	{ID: "watchdog-status", Label: "Статус watchdog", Description: "Показать статус daemon watchdog", Command: []string{"/opt/bin/vless-go-watchdog", "status"}, Timeout: 10 * time.Second, Group: "overview"},
	{ID: "doctor", Label: "Запустить doctor", Description: "Полная диагностика установки", Command: []string{"/opt/bin/vless-go-doctor"}, Timeout: 90 * time.Second, Group: "diagnostics"},
	{ID: "switch-primary", Label: "Переключить на основной", Description: "Активировать primary source", Command: []string{"/opt/bin/vless-go-failover", "switch", "primary"}, Timeout: 60 * time.Second, Group: "failover"},
	{ID: "switch-backup", Label: "Переключить на резервный", Description: "Активировать backup source", Command: []string{"/opt/bin/vless-go-failover", "switch", "backup"}, Timeout: 60 * time.Second, Group: "failover", Danger: true},
	{ID: "update-all", Label: "Обновить активный конфиг", Description: "Перегенерировать активный Xray config", Command: []string{"/opt/bin/vless-go-failover", "update-active"}, Timeout: 90 * time.Second, Group: "sources"},
	{ID: "auto-update-run", Label: "Запустить автообновление", Description: "Выполнить selector-aware auto-update сейчас", Command: []string{"/opt/bin/vless-go-auto-update", "run"}, Timeout: 120 * time.Second, Group: "updates"},
	{ID: "restart-xray", Label: "Перезапустить Xray", Description: "Перезапустить S24xray", Command: []string{"/opt/etc/init.d/S24xray", "restart"}, Timeout: 30 * time.Second, Group: "maintenance"},
	{ID: "restart-watchdog", Label: "Перезапустить watchdog", Description: "Перезапустить S26vless-go-watchdog", Command: []string{"/opt/etc/init.d/S26vless-go-watchdog", "restart"}, Timeout: 30 * time.Second, Group: "watchdog"},
	{ID: "history", Label: "История переключений", Description: "Показать последние переключения", Command: []string{"/opt/bin/vless-go-history", "tail", "80"}, Timeout: 20 * time.Second, Group: "logs"},
	{ID: "cleanup-dry-run", Label: "Проверка очистки", Description: "Предпросмотр безопасной очистки", Command: []string{"/opt/bin/vless-go-cleanup", "--dry-run"}, Timeout: 30 * time.Second, Group: "maintenance"},
	{ID: "xray-core-update", Label: "Обновить Xray-core", Description: "Обновить Xray-core с созданием backup", Command: []string{"/opt/bin/vless-go-xray-core-update", "--backup"}, Timeout: 240 * time.Second, Group: "updates", Danger: true},
}

var page = template.Must(template.New("page").Funcs(template.FuncMap{
	"actionsIn": actionsIn,
}).Parse(`<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>VLESS Go Dashboard</title>
<style>
:root{--bg:#09090b;--panel:#18181b;--line:#3f3f46;--text:#fafafa;--muted:#a1a1aa;--blue:#2563eb;--purple:#7c3aed;--green:#22c55e;--amber:#d97706;--red:#b91c1c;--cyan:#38bdf8}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font-family:system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}.content{padding:28px;max-width:1240px;margin:0 auto}.topbar{display:flex;gap:18px;align-items:flex-start;justify-content:space-between;margin-bottom:22px;padding:20px 22px;background:#111111;border:1px solid var(--line);border-radius:22px}.title h1{font-size:34px;margin:0 0 8px}.title p{margin:0;color:var(--muted)}.listen{margin-top:10px;color:var(--muted);font-size:13px}.badge{display:inline-flex;gap:8px;align-items:center;border:1px solid #14532d;background:#052e16;color:#bbf7d0;padding:10px 14px;border-radius:999px;font-weight:700;white-space:nowrap}.dot{width:9px;height:9px;border-radius:99px;background:var(--green);box-shadow:0 0 16px var(--green)}.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:14px;margin-bottom:22px}.metric{background:var(--panel);border:1px solid var(--line);border-radius:18px;padding:18px;min-height:108px;position:relative;overflow:hidden}.metric:before{content:"";position:absolute;left:0;top:18px;bottom:18px;width:6px;border-radius:6px;background:var(--accent,var(--blue))}.metric .label{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.08em;margin-left:14px}.metric .value{font-size:25px;font-weight:800;margin:12px 0 0 14px}.grid{display:grid;grid-template-columns:1.1fr .9fr;gap:18px}.panel{background:var(--panel);border:1px solid var(--line);border-radius:18px;padding:18px;margin-bottom:18px}.panel h2{margin:0 0 14px;font-size:21px}.panel p{color:var(--muted)}.section-kicker{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.08em;margin-bottom:8px}.action-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(185px,1fr));gap:12px}.button,button{width:100%;padding:12px 14px;border:0;border-radius:11px;background:var(--blue);color:white;font-weight:750;cursor:pointer}.button:hover,button:hover{filter:brightness(1.08)}.secondary button{background:#3f3f46}.purple button{background:var(--purple)}.danger button{background:var(--red)}.amber button{background:var(--amber)}.cyan button{background:#0891b2}.muted{color:var(--muted);font-size:13px}.desc{color:var(--muted);font-size:12px;margin-top:7px;line-height:1.35}.form-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:12px}label{font-size:13px;color:#d4d4d8;font-weight:700}input,select{width:100%;margin:7px 0 12px;padding:11px 12px;border-radius:10px;border:1px solid #52525b;background:#09090b;color:#f4f4f5}pre{white-space:pre-wrap;word-break:break-word;background:#050505;border:1px solid var(--line);border-radius:14px;padding:15px;max-height:560px;overflow:auto;color:#d4d4d8}.split{display:grid;grid-template-columns:1fr 1fr;gap:12px}.footer-note{color:var(--muted);font-size:12px;line-height:1.5}@media(max-width:920px){.content{padding:18px}.topbar{display:block}.badge{margin-top:16px}.grid{grid-template-columns:1fr}.split{grid-template-columns:1fr}}
</style>
</head>
<body>
<main class="content">
  <section class="topbar">
    <div class="title"><h1>VLESS Go Dashboard</h1><p>Full Go/Entware dashboard для Xray VLESS failover.</p><div class="listen">Адрес: {{.Listen}}</div></div>
    <div class="badge"><span class="dot"></span>{{.HealthState}}</div>
  </section>

  <section class="cards">
    <div class="metric" style="--accent:var(--green)"><div class="label">Активный слот</div><div class="value">{{.Active}}</div></div>
    <div class="metric" style="--accent:var(--cyan)"><div class="label">Основной</div><div class="value">{{.PrimaryState}}</div></div>
    <div class="metric" style="--accent:var(--purple)"><div class="label">Резервный</div><div class="value">{{.BackupState}}</div></div>
    <div class="metric" style="--accent:var(--amber)"><div class="label">Watchdog</div><div class="value">{{.WatchdogState}}</div></div>
  </section>

  <div class="grid">
    <div>
      <section class="panel"><div class="section-kicker">Failover</div><h2>Управление переключением</h2><div class="action-grid">
        {{range actionsIn .Actions "failover"}}<form method="post" action="/action" class="{{if .Danger}}danger{{else}}purple{{end}}"><input type="hidden" name="id" value="{{.ID}}"><input type="hidden" name="token" value="{{$.Token}}"><button type="submit">{{.Label}}</button><div class="desc">{{.Description}}</div></form>{{end}}
        {{range actionsIn .Actions "overview"}}<form method="post" action="/action" class="secondary"><input type="hidden" name="id" value="{{.ID}}"><input type="hidden" name="token" value="{{$.Token}}"><button type="submit">{{.Label}}</button><div class="desc">{{.Description}}</div></form>{{end}}
      </div></section>

      <section class="panel"><div class="section-kicker">Sources</div><h2>Источники</h2><form method="post" action="/set-source"><input type="hidden" name="token" value="{{.Token}}"><div class="form-grid"><div><label>Слот</label><select name="slot"><option value="primary">primary / основной</option><option value="backup">backup / резервный</option></select></div><div><label>Selector</label><input name="selector" placeholder="first или index:7" value="first"></div></div><label>VLESS-ссылка или URL подписки</label><input name="source" type="password" autocomplete="off" placeholder="vless://... или https://..."><button type="submit">Сохранить источник</button></form><p class="footer-note">Приватные значения источников принимаются формой, но не выводятся обратно на страницу.</p></section>

      <section class="panel"><div class="section-kicker">Selectors</div><h2>Выбор профилей</h2><form method="post" action="/set-selector"><input type="hidden" name="token" value="{{.Token}}"><div class="split"><div><label>Selector основного</label><input name="primary" value="{{.PrimarySelector}}"></div><div><label>Selector резервного</label><input name="backup" value="{{.BackupSelector}}"></div></div><button type="submit">Сохранить selectors</button></form></section>

      <section class="panel"><div class="section-kicker">Watchdog</div><h2>Автовосстановление</h2><form method="post" action="/set-recovery"><input type="hidden" name="token" value="{{.Token}}"><label>Возврат с backup на primary</label><select name="enabled"><option value="1">включён</option><option value="0">выключен</option></select><button type="submit">Сохранить и перезапустить watchdog</button><p class="footer-note">Текущее значение AUTO_RECOVER_PRIMARY={{.Recovery}}</p></form><div class="action-grid">{{range actionsIn .Actions "watchdog"}}<form method="post" action="/action" class="secondary"><input type="hidden" name="id" value="{{.ID}}"><input type="hidden" name="token" value="{{$.Token}}"><button type="submit">{{.Label}}</button><div class="desc">{{.Description}}</div></form>{{end}}</div></section>
    </div>

    <div>
      <section class="panel"><div class="section-kicker">Status</div><h2>Системный статус</h2><pre>{{.Status}}</pre></section>
      <section class="panel"><div class="section-kicker">Updates</div><h2>Обновления</h2><div class="action-grid">{{range actionsIn .Actions "updates"}}<form method="post" action="/action" class="{{if .Danger}}danger{{else}}cyan{{end}}"><input type="hidden" name="id" value="{{.ID}}"><input type="hidden" name="token" value="{{$.Token}}"><button type="submit">{{.Label}}</button><div class="desc">{{.Description}}</div></form>{{end}}{{range actionsIn .Actions "sources"}}<form method="post" action="/action" class="cyan"><input type="hidden" name="id" value="{{.ID}}"><input type="hidden" name="token" value="{{$.Token}}"><button type="submit">{{.Label}}</button><div class="desc">{{.Description}}</div></form>{{end}}</div></section>
      <section class="panel"><div class="section-kicker">Diagnostics</div><h2>Диагностика и обслуживание</h2><div class="action-grid">{{range actionsIn .Actions "diagnostics"}}<form method="post" action="/action"><input type="hidden" name="id" value="{{.ID}}"><input type="hidden" name="token" value="{{$.Token}}"><button type="submit">{{.Label}}</button><div class="desc">{{.Description}}</div></form>{{end}}{{range actionsIn .Actions "maintenance"}}<form method="post" action="/action" class="secondary"><input type="hidden" name="id" value="{{.ID}}"><input type="hidden" name="token" value="{{$.Token}}"><button type="submit">{{.Label}}</button><div class="desc">{{.Description}}</div></form>{{end}}</div></section>
      <section class="panel"><div class="section-kicker">Logs</div><h2>Логи и история</h2><div class="action-grid">{{range actionsIn .Actions "logs"}}<form method="post" action="/action" class="secondary"><input type="hidden" name="id" value="{{.ID}}"><input type="hidden" name="token" value="{{$.Token}}"><button type="submit">{{.Label}}</button><div class="desc">{{.Description}}</div></form>{{end}}</div></section>
    </div>
  </div>

  {{if .Output}}<section class="panel"><div class="section-kicker">Output</div><h2>Вывод команды</h2><pre>{{.Output}}</pre></section>{{end}}
  <section class="panel"><div class="section-kicker">Settings</div><h2>Настройки</h2><p class="footer-note">Этот опциональный LAN dashboard работает на настроенном адресе прослушивания. Используй его только в доверенной локальной сети. VLESS/URL источники отправляются как password-поля и не выводятся обратно на страницу.</p></section>
</main>
</body>
</html>`))

func main() {
	listen := envOrConfig()
	token, err := ensureToken(tokenPath)
	if err != nil {
		log.Fatalf("токен: %v", err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		render(w, listen, token, "")
	})
	mux.HandleFunc("/action", post(token, func(r *http.Request) string { return runAction(r.FormValue("id")) }, listen))
	mux.HandleFunc("/set-source", post(token, handleSetSource, listen))
	mux.HandleFunc("/set-selector", post(token, handleSetSelector, listen))
	mux.HandleFunc("/set-recovery", post(token, handleSetRecovery, listen))
	ln, err := net.Listen("tcp", listen)
	if err != nil {
		log.Fatalf("не удалось слушать %s: %v", listen, err)
	}
	log.Printf("vless-go-web запущен: http://%s", listen)
	log.Fatal(http.Serve(ln, mux))
}

func actionsIn(items []action, group string) []action {
	out := []action{}
	for _, item := range items {
		if item.Group == group {
			out = append(out, item)
		}
	}
	return out
}

func post(token string, fn func(*http.Request) string, listen string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "нужен POST-запрос", http.StatusMethodNotAllowed)
			return
		}
		if r.FormValue("token") != token {
			http.Error(w, "неверный токен", http.StatusForbidden)
			return
		}
		render(w, listen, token, fn(r))
	}
}

func envOrConfig() string {
	if v := strings.TrimSpace(os.Getenv("VLESS_GO_WEB_LISTEN")); v != "" {
		return v
	}
	data, err := os.ReadFile("/opt/etc/xray/vless-go-web.conf")
	if err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			line = strings.TrimSpace(line)
			if strings.HasPrefix(line, "LISTEN=") {
				return strings.Trim(strings.TrimPrefix(line, "LISTEN="), "\"")
			}
		}
	}
	return defaultListen
}

func ensureToken(path string) (string, error) {
	if data, err := os.ReadFile(path); err == nil {
		if tok := strings.TrimSpace(string(data)); tok != "" {
			return tok, nil
		}
	}
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	tok := hex.EncodeToString(b)
	if err := os.MkdirAll("/opt/etc/xray", 0700); err != nil {
		return "", err
	}
	if err := os.WriteFile(path, []byte(tok+"\n"), 0600); err != nil {
		return "", err
	}
	return tok, nil
}

func render(w http.ResponseWriter, listen, token, output string) {
	status := quickStatus()
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_ = page.Execute(w, pageData{
		Listen:          listen,
		Token:           token,
		Status:          status,
		Output:          output,
		Actions:         actions,
		PrimarySelector: readFile("/opt/etc/xray/vless-go.primary.selector", "first"),
		BackupSelector:  readFile("/opt/etc/xray/vless-go.backup.selector", "first"),
		Recovery:        readRecovery(),
		Active:          parseStatus(status, "active:", "unknown"),
		PrimaryState:    parseStatus(status, "primary:", "unknown"),
		BackupState:     parseStatus(status, "backup:", "unknown"),
		WatchdogState:   parseStatus(status, "daemon:", "unknown"),
		HealthState:     healthLabel(status),
	})
}

func readFile(path, def string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return def
	}
	v := strings.TrimSpace(string(data))
	if v == "" {
		return def
	}
	return v
}

func readRecovery() string {
	data, err := os.ReadFile("/opt/etc/xray/vless-go-watchdog.conf")
	if err != nil {
		return "unknown"
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "AUTO_RECOVER_PRIMARY=") {
			return strings.TrimSpace(strings.TrimPrefix(line, "AUTO_RECOVER_PRIMARY="))
		}
	}
	return "0"
}

func parseStatus(status, key, def string) string {
	for _, line := range strings.Split(status, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, key) {
			return strings.TrimSpace(strings.TrimPrefix(line, key))
		}
	}
	return def
}

func healthLabel(status string) string {
	lower := strings.ToLower(status)
	if strings.Contains(lower, "daemon: running") || strings.Contains(lower, "daemon: alive") {
		return "ОНЛАЙН"
	}
	if strings.Contains(lower, "not running") || strings.Contains(lower, "fail") {
		return "НУЖНА ПРОВЕРКА"
	}
	return "ГОТОВ"
}

func quickStatus() string {
	parts := []string{}
	for _, cmd := range [][]string{{"/opt/bin/vless-go-failover", "status"}, {"/opt/bin/vless-go-watchdog", "status"}} {
		parts = append(parts, "$ "+strings.Join(cmd, " "))
		parts = append(parts, runCommand(cmd, 8*time.Second))
	}
	return strings.Join(parts, "\n\n")
}

func runAction(id string) string {
	for _, a := range actions {
		if a.ID == id {
			return "$ " + strings.Join(a.Command, " ") + "\n" + runCommand(a.Command, a.Timeout)
		}
	}
	return "неизвестное действие: " + id
}

func handleSetSource(r *http.Request) string {
	slot := r.FormValue("slot")
	source := strings.TrimSpace(r.FormValue("source"))
	selector := strings.TrimSpace(r.FormValue("selector"))
	if selector == "" {
		selector = "first"
	}
	if slot != "primary" && slot != "backup" {
		return "ОШИБКА: неверный слот"
	}
	if source == "" {
		return "ОШИБКА: источник пустой"
	}
	cmd := []string{"/opt/bin/vless-go-failover", "set-" + slot, source, "--selector", selector}
	return "$ /opt/bin/vless-go-failover set-" + slot + " <скрыто> --selector " + selector + "\n" + runCommand(cmd, 90*time.Second)
}

func handleSetSelector(r *http.Request) string {
	out := []string{}
	p := strings.TrimSpace(r.FormValue("primary"))
	b := strings.TrimSpace(r.FormValue("backup"))
	if p != "" {
		cmd := []string{"/opt/bin/vless-go-failover", "set-selector", "primary", p}
		out = append(out, "$ "+strings.Join(cmd, " ")+"\n"+runCommand(cmd, 30*time.Second))
	}
	if b != "" {
		cmd := []string{"/opt/bin/vless-go-failover", "set-selector", "backup", b}
		out = append(out, "$ "+strings.Join(cmd, " ")+"\n"+runCommand(cmd, 30*time.Second))
	}
	return strings.Join(out, "\n")
}

func handleSetRecovery(r *http.Request) string {
	v := r.FormValue("enabled")
	if v != "0" && v != "1" {
		return "ОШИБКА: неверное значение recovery"
	}
	conf := "/opt/etc/xray/vless-go-watchdog.conf"
	data, err := os.ReadFile(conf)
	if err != nil {
		return "ОШИБКА: " + err.Error()
	}
	lines := strings.Split(string(data), "\n")
	found := false
	for i, line := range lines {
		if strings.HasPrefix(strings.TrimSpace(line), "AUTO_RECOVER_PRIMARY=") {
			lines[i] = "AUTO_RECOVER_PRIMARY=" + v
			found = true
		}
	}
	if !found {
		lines = append(lines, "AUTO_RECOVER_PRIMARY="+v)
	}
	if err := os.WriteFile(conf, []byte(strings.Join(lines, "\n")), 0600); err != nil {
		return "ОШИБКА: " + err.Error()
	}
	return "AUTO_RECOVER_PRIMARY=" + v + "\n" + runCommand([]string{"/opt/etc/init.d/S26vless-go-watchdog", "restart"}, 30*time.Second)
}

func runCommand(cmd []string, timeout time.Duration) string {
	if len(cmd) == 0 {
		return "пустая команда"
	}
	if _, err := os.Stat(cmd[0]); err != nil {
		return fmt.Sprintf("не найдено: %s", cmd[0])
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	c := exec.CommandContext(ctx, cmd[0], cmd[1:]...)
	var out bytes.Buffer
	c.Stdout = &out
	c.Stderr = &out
	err := c.Run()
	if ctx.Err() == context.DeadlineExceeded {
		return out.String() + "\nОШИБКА: команда выполнялась слишком долго"
	}
	if err != nil {
		return out.String() + "\nОШИБКА: " + err.Error()
	}
	return out.String()
}
