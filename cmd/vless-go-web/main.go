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
	defaultListen = "127.0.0.1:18088"
	tokenPath     = "/opt/etc/xray/vless-go-web.token"
)

type action struct { ID, Label, Description string; Command []string; Timeout time.Duration }
type pageData struct { Listen, Token, Status, Output, PrimarySelector, BackupSelector, Recovery string; Actions []action }

var actions = []action{
	{ID:"status", Label:"Status", Description:"Show failover and watchdog status", Command:[]string{"/opt/bin/vless-go-failover","status"}, Timeout:10*time.Second},
	{ID:"watchdog-status", Label:"Watchdog status", Description:"Show watchdog daemon status", Command:[]string{"/opt/bin/vless-go-watchdog","status"}, Timeout:10*time.Second},
	{ID:"doctor", Label:"Doctor", Description:"Run full diagnostics", Command:[]string{"/opt/bin/vless-go-doctor"}, Timeout:90*time.Second},
	{ID:"switch-primary", Label:"Switch to primary", Description:"Switch active config to primary", Command:[]string{"/opt/bin/vless-go-failover","switch","primary"}, Timeout:60*time.Second},
	{ID:"switch-backup", Label:"Switch to backup", Description:"Switch active config to backup", Command:[]string{"/opt/bin/vless-go-failover","switch","backup"}, Timeout:60*time.Second},
	{ID:"update-all", Label:"Update active config", Description:"Regenerate active Xray config", Command:[]string{"/opt/bin/vless-go-failover","update-active"}, Timeout:90*time.Second},
	{ID:"auto-update-run", Label:"Run auto-update", Description:"Run selector-aware auto-update now", Command:[]string{"/opt/bin/vless-go-auto-update","run"}, Timeout:120*time.Second},
	{ID:"restart-xray", Label:"Restart Xray", Description:"Restart S24xray", Command:[]string{"/opt/etc/init.d/S24xray","restart"}, Timeout:30*time.Second},
	{ID:"restart-watchdog", Label:"Restart watchdog", Description:"Restart S26vless-go-watchdog", Command:[]string{"/opt/etc/init.d/S26vless-go-watchdog","restart"}, Timeout:30*time.Second},
	{ID:"history", Label:"Switch history", Description:"Show recent switch history", Command:[]string{"/opt/bin/vless-go-history","tail","80"}, Timeout:20*time.Second},
	{ID:"cleanup-dry-run", Label:"Cleanup dry-run", Description:"Preview safe cleanup", Command:[]string{"/opt/bin/vless-go-cleanup","--dry-run"}, Timeout:30*time.Second},
	{ID:"xray-core-update", Label:"Xray-core update", Description:"Update Xray-core with backup", Command:[]string{"/opt/bin/vless-go-xray-core-update","--backup"}, Timeout:240*time.Second},
}

var page = template.Must(template.New("page").Parse(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>VLESS Go Web</title><style>
body{font-family:system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;margin:0;background:#0f172a;color:#e5e7eb}header{padding:20px;background:#111827;border-bottom:1px solid #374151}main{padding:20px;max-width:1180px;margin:0 auto}.card{background:#111827;border:1px solid #374151;border-radius:14px;padding:16px;margin:14px 0;box-shadow:0 10px 24px rgba(0,0,0,.18)}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:12px}.grid2{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:14px}button{width:100%;padding:12px 14px;border:0;border-radius:10px;background:#2563eb;color:white;font-weight:650;cursor:pointer}button:hover{background:#1d4ed8}.danger button{background:#b91c1c}.danger button:hover{background:#991b1b}.muted{color:#9ca3af;font-size:14px}.ok{color:#86efac}.warn{color:#fde68a}pre{white-space:pre-wrap;word-break:break-word;background:#020617;border:1px solid #334155;border-radius:12px;padding:14px;max-height:520px;overflow:auto}input,select{padding:10px;border-radius:8px;border:1px solid #475569;background:#020617;color:#e5e7eb;width:100%;box-sizing:border-box;margin:6px 0 10px}.row{display:flex;gap:10px;align-items:center}.row>*{flex:1}a{color:#93c5fd}label{font-weight:650;font-size:14px}</style></head><body>
<header><h1>VLESS Go Web</h1><div class="muted">Optional Full Go/Entware web interface. Listen: {{.Listen}}</div></header><main>
<div class="card"><h2>Status</h2><pre>{{.Status}}</pre></div>
<div class="card"><h2>Quick actions</h2><div class="grid">{{range .Actions}}<form method="post" action="/action"><input type="hidden" name="id" value="{{.ID}}"><input type="hidden" name="token" value="{{$.Token}}"><button type="submit">{{.Label}}</button><div class="muted">{{.Description}}</div></form>{{end}}</div></div>
<div class="grid2">
<div class="card"><h2>Set source</h2><form method="post" action="/set-source"><input type="hidden" name="token" value="{{.Token}}"><label>Slot</label><select name="slot"><option value="primary">primary</option><option value="backup">backup</option></select><label>VLESS link or subscription URL</label><input name="source" type="password" autocomplete="off" placeholder="vless://... or https://..."><label>Selector</label><input name="selector" placeholder="first or index:7" value="first"><button type="submit">Save source</button></form><p class="muted">Private source value is not displayed.</p></div>
<div class="card"><h2>Selectors</h2><form method="post" action="/set-selector"><input type="hidden" name="token" value="{{.Token}}"><label>Primary selector</label><input name="primary" value="{{.PrimarySelector}}"><label>Backup selector</label><input name="backup" value="{{.BackupSelector}}"><button type="submit">Save selectors</button></form></div>
<div class="card"><h2>Automation</h2><form method="post" action="/set-recovery"><input type="hidden" name="token" value="{{.Token}}"><label>backup -> primary recovery</label><select name="enabled"><option value="1">enabled</option><option value="0">disabled</option></select><button type="submit">Set recovery</button><p class="muted">Current AUTO_RECOVER_PRIMARY={{.Recovery}}</p></form></div>
</div>
{{if .Output}}<div class="card"><h2>Command output</h2><pre>{{.Output}}</pre></div>{{end}}
<div class="card muted"><p>Security: by default this service listens on 127.0.0.1 only. Use SSH tunnel or set listen explicitly in /opt/etc/xray/vless-go-web.conf if LAN access is required. Source values are accepted by form but never printed back.</p></div>
</main></body></html>`))

func main() {
	listen := envOrConfig(); token, err := ensureToken(tokenPath); if err != nil { log.Fatalf("token: %v", err) }
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request){ if r.URL.Path!="/"{http.NotFound(w,r);return}; render(w, listen, token, "") })
	mux.HandleFunc("/action", post(token, func(r *http.Request) string { return runAction(r.FormValue("id")) }, listen))
	mux.HandleFunc("/set-source", post(token, handleSetSource, listen))
	mux.HandleFunc("/set-selector", post(token, handleSetSelector, listen))
	mux.HandleFunc("/set-recovery", post(token, handleSetRecovery, listen))
	ln, err := net.Listen("tcp", listen); if err != nil { log.Fatalf("listen %s: %v", listen, err) }
	log.Printf("vless-go-web listening on http://%s", listen); log.Fatal(http.Serve(ln, mux))
}

func post(token string, fn func(*http.Request) string, listen string) http.HandlerFunc { return func(w http.ResponseWriter, r *http.Request){ if r.Method != http.MethodPost { http.Error(w,"POST required",http.StatusMethodNotAllowed); return }; if r.FormValue("token") != token { http.Error(w,"invalid token",http.StatusForbidden); return }; render(w, listen, token, fn(r)) } }

func envOrConfig() string { if v:=strings.TrimSpace(os.Getenv("VLESS_GO_WEB_LISTEN")); v!=""{return v}; data,err:=os.ReadFile("/opt/etc/xray/vless-go-web.conf"); if err==nil{ for _,line:=range strings.Split(string(data),"\n"){ line=strings.TrimSpace(line); if strings.HasPrefix(line,"LISTEN="){return strings.Trim(strings.TrimPrefix(line,"LISTEN="),"\"")} } }; return defaultListen }
func ensureToken(path string)(string,error){ if data,err:=os.ReadFile(path);err==nil{ if tok:=strings.TrimSpace(string(data));tok!=""{return tok,nil} }; b:=make([]byte,16); if _,err:=rand.Read(b);err!=nil{return "",err}; tok:=hex.EncodeToString(b); if err:=os.MkdirAll("/opt/etc/xray",0700);err!=nil{return "",err}; if err:=os.WriteFile(path,[]byte(tok+"\n"),0600);err!=nil{return "",err}; return tok,nil }

func render(w http.ResponseWriter, listen, token, output string){ w.Header().Set("Content-Type","text/html; charset=utf-8"); _=page.Execute(w,pageData{Listen:listen,Token:token,Status:quickStatus(),Output:output,Actions:actions,PrimarySelector:readFile("/opt/etc/xray/vless-go.primary.selector","first"),BackupSelector:readFile("/opt/etc/xray/vless-go.backup.selector","first"),Recovery:readRecovery()}) }
func readFile(path, def string) string { data,err:=os.ReadFile(path); if err!=nil{return def}; v:=strings.TrimSpace(string(data)); if v==""{return def}; return v }
func readRecovery() string { data,err:=os.ReadFile("/opt/etc/xray/vless-go-watchdog.conf"); if err!=nil{return "unknown"}; for _,line:=range strings.Split(string(data),"\n"){ if strings.HasPrefix(strings.TrimSpace(line),"AUTO_RECOVER_PRIMARY="){return strings.TrimSpace(strings.TrimPrefix(line,"AUTO_RECOVER_PRIMARY="))} }; return "0" }

func quickStatus() string { parts:=[]string{}; for _,cmd:= range [][]string{{"/opt/bin/vless-go-failover","status"},{"/opt/bin/vless-go-watchdog","status"}}{ parts=append(parts,"$ "+strings.Join(cmd," ")); parts=append(parts,runCommand(cmd,8*time.Second))}; return strings.Join(parts,"\n\n") }
func runAction(id string) string { for _,a:=range actions{ if a.ID==id{return "$ "+strings.Join(a.Command," ")+"\n"+runCommand(a.Command,a.Timeout)} }; return "unknown action: "+id }

func handleSetSource(r *http.Request) string { slot:=r.FormValue("slot"); source:=strings.TrimSpace(r.FormValue("source")); selector:=strings.TrimSpace(r.FormValue("selector")); if selector==""{selector="first"}; if slot!="primary"&&slot!="backup"{return "ERROR: invalid slot"}; if source==""{return "ERROR: source is empty"}; cmd:=[]string{"/opt/bin/vless-go-failover","set-"+slot,source,"--selector",selector}; return "$ /opt/bin/vless-go-failover set-"+slot+" <hidden> --selector "+selector+"\n"+runCommand(cmd,90*time.Second) }
func handleSetSelector(r *http.Request) string { out:=[]string{}; p:=strings.TrimSpace(r.FormValue("primary")); b:=strings.TrimSpace(r.FormValue("backup")); if p!=""{cmd:=[]string{"/opt/bin/vless-go-failover","set-selector","primary",p}; out=append(out,"$ "+strings.Join(cmd," ")+"\n"+runCommand(cmd,30*time.Second))}; if b!=""{cmd:=[]string{"/opt/bin/vless-go-failover","set-selector","backup",b}; out=append(out,"$ "+strings.Join(cmd," ")+"\n"+runCommand(cmd,30*time.Second))}; return strings.Join(out,"\n") }
func handleSetRecovery(r *http.Request) string { v:=r.FormValue("enabled"); if v!="0"&&v!="1"{return "ERROR: invalid recovery value"}; conf:="/opt/etc/xray/vless-go-watchdog.conf"; data,err:=os.ReadFile(conf); if err!=nil{return "ERROR: "+err.Error()}; lines:=strings.Split(string(data),"\n"); found:=false; for i,line:=range lines{ if strings.HasPrefix(strings.TrimSpace(line),"AUTO_RECOVER_PRIMARY="){lines[i]="AUTO_RECOVER_PRIMARY="+v; found=true} }; if !found{lines=append(lines,"AUTO_RECOVER_PRIMARY="+v)}; if err:=os.WriteFile(conf,[]byte(strings.Join(lines,"\n")),0600);err!=nil{return "ERROR: "+err.Error()}; return "AUTO_RECOVER_PRIMARY="+v+"\n"+runCommand([]string{"/opt/etc/init.d/S26vless-go-watchdog","restart"},30*time.Second) }

func runCommand(cmd []string, timeout time.Duration) string { if len(cmd)==0{return "empty command"}; if _,err:=os.Stat(cmd[0]);err!=nil{return fmt.Sprintf("not found: %s",cmd[0])}; ctx,cancel:=context.WithTimeout(context.Background(),timeout); defer cancel(); c:=exec.CommandContext(ctx,cmd[0],cmd[1:]...); var out bytes.Buffer; c.Stdout=&out; c.Stderr=&out; err:=c.Run(); if ctx.Err()==context.DeadlineExceeded{return out.String()+"\nERROR: command timed out"}; if err!=nil{return out.String()+"\nERROR: "+err.Error()}; return out.String() }
