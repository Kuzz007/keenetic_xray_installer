package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Config struct { ConfigPath string; Listen string; BotToken string; AdminUserID int64; Routers map[string]*Router; Groups []string }
type Router struct { ID string; Name string; Token string; Group string; LastSeen time.Time; Status string; Queue []Command; Results []Result }
type Command struct { ID string `json:"id"`; Action string `json:"action"`; Slot string `json:"slot,omitempty"`; Selector string `json:"selector,omitempty"`; Source string `json:"source,omitempty"` }
type Result struct { CommandID string `json:"command_id"`; RouterID string `json:"router_id"`; OK bool `json:"ok"`; Output string `json:"output"`; At string `json:"at,omitempty"` }
type ActiveMenu struct { ChatID int64; MessageID int; RouterID string }
type Server struct { cfg Config; mu sync.Mutex; lastUpdID int64; activeMenus map[string]ActiveMenu }

func main() {
	cfgPath := flag.String("config", "/etc/xray-go-control-server.conf", "config path")
	flag.Parse()
	cfg, err := loadConfig(*cfgPath); if err != nil { log.Fatalf("config: %v", err) }
	s := &Server{cfg: cfg, activeMenus: map[string]ActiveMenu{}}
	mux := http.NewServeMux()
	mux.HandleFunc("/agent/poll", s.handlePoll)
	mux.HandleFunc("/agent/result", s.handleResult)
	mux.HandleFunc("/health", handleHealth)
	mux.HandleFunc("/version", handleVersion)
	go s.telegramLoop()
	log.Printf("xray-go-control-server listen=%s routers=%d %s", cfg.Listen, len(cfg.Routers), versionLine())
	log.Fatal(http.ListenAndServe(cfg.Listen, mux))
}

func (s *Server) handlePoll(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost { http.Error(w, "POST required", http.StatusMethodNotAllowed); return }
	rt := s.authRouter(r); if rt == nil { http.Error(w, "unauthorized", http.StatusUnauthorized); return }
	var hb struct{ RouterID, Name, Status string }; _ = json.NewDecoder(r.Body).Decode(&hb)
	s.mu.Lock(); rt.LastSeen = time.Now(); if hb.Status != "" { rt.Status = hb.Status }
	var cmd *Command; if len(rt.Queue) > 0 { c := rt.Queue[0]; rt.Queue = rt.Queue[1:]; cmd = &c }
	s.mu.Unlock(); _ = json.NewEncoder(w).Encode(map[string]any{"command": cmd})
}

func (s *Server) handleResult(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost { http.Error(w, "POST required", http.StatusMethodNotAllowed); return }
	rt := s.authRouter(r); if rt == nil { http.Error(w, "unauthorized", http.StatusUnauthorized); return }
	var res Result; if err := json.NewDecoder(r.Body).Decode(&res); err != nil { http.Error(w, err.Error(), http.StatusBadRequest); return }
	res.At = time.Now().Format("2006-01-02 15:04:05"); routerID, routerName := rt.ID, rt.Name
	s.mu.Lock(); rt.Results = append(rt.Results, res); if len(rt.Results) > 20 { rt.Results = rt.Results[len(rt.Results)-20:] }; s.mu.Unlock()
	_ = json.NewEncoder(w).Encode(map[string]string{"ok":"1"})
	if s.cfg.BotToken != "" && s.cfg.AdminUserID != 0 {
		if isRoutesResult(res.CommandID) { if !s.editActiveRoutesResult(routerID, res) { s.sendMessage(s.cfg.AdminUserID, prettyResultMessage(routerName, res)) } } else if isCardPreferredResult(res.CommandID) { if !s.editActiveRouterResult(routerID, res) { s.sendMessage(s.cfg.AdminUserID, prettyResultMessage(routerName, res)) } } else if isStandaloneResult(res.CommandID) { s.sendMessage(s.cfg.AdminUserID, prettyResultMessage(routerName, res)) } else if !s.editActiveRouterResult(routerID, res) { s.sendMessage(s.cfg.AdminUserID, prettyResultMessage(routerName, res)) }
		if summary, ok := s.recordDoctorAllResult(routerName, res); ok { s.sendMessage(s.cfg.AdminUserID, summary) }
		if summary, ok := s.recordUpdateScriptsAllResult(routerName, res); ok { s.sendMessage(s.cfg.AdminUserID, summary) }
	}
}

func isStandaloneResult(commandID string) bool { return strings.HasPrefix(commandID, "slot_change") || strings.HasPrefix(commandID, "agent_start") || strings.HasPrefix(commandID, "doctor_all") }
func isCardPreferredResult(commandID string) bool { return strings.HasPrefix(commandID, "set_primary_source-") || strings.HasPrefix(commandID, "set_backup_source-") }
func isRoutesResult(commandID string) bool { return strings.HasPrefix(commandID, "routes_list-") || strings.HasPrefix(commandID, "routes_preview-") }
func (s *Server) authRouter(r *http.Request) *Router { auth := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "); if auth == "" { return nil }; s.mu.Lock(); defer s.mu.Unlock(); for _, rt := range s.cfg.Routers { if rt.Token == auth { return rt } }; return nil }

func (s *Server) telegramLoop() { if s.cfg.BotToken == "" || s.cfg.AdminUserID == 0 { return }; if err := s.setBotCommands(); err != nil { log.Printf("telegram setMyCommands: %v", err) }; for { updates, err := s.getUpdates(); if err != nil { log.Printf("telegram: %v", err); time.Sleep(5*time.Second); continue }; for _, u := range updates { s.handleTelegramUpdate(u) } } }

type tgUpdate struct { UpdateID int64 `json:"update_id"`; Message *tgMessage `json:"message"`; CallbackQuery *tgCallbackQuery `json:"callback_query"` }
type tgMessage struct { MessageID int `json:"message_id"`; Chat tgChat `json:"chat"`; From tgUser `json:"from"`; Text string `json:"text"` }
type tgChat struct { ID int64 `json:"id"` }
type tgUser struct { ID int64 `json:"id"` }
type tgCallbackQuery struct { ID string `json:"id"`; From tgUser `json:"from"`; Message *tgMessage `json:"message"`; Data string `json:"data"` }
type inlineKeyboard struct { InlineKeyboard [][]inlineButton `json:"inline_keyboard"` }
type inlineButton struct { Text string `json:"text"`; CallbackData string `json:"callback_data"` }

func (s *Server) setBotCommands() error {
	payload := map[string]any{"commands": []map[string]string{{"command":"menu","description":"Открыть меню управления"},{"command":"routers","description":"Список роутеров"},{"command":"add_router","description":"Добавить роутер"},{"command":"help","description":"Помощь"}}}
	body, _ := json.Marshal(payload); url := fmt.Sprintf("https://api.telegram.org/bot%s/setMyCommands", s.cfg.BotToken)
	resp, err := http.Post(url, "application/json", bytes.NewReader(body)); if err != nil { return err }; defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 { b,_ := io.ReadAll(io.LimitReader(resp.Body,4096)); return fmt.Errorf("telegram setMyCommands status=%s body=%s", resp.Status, string(b)) }
	var data struct{ OK bool `json:"ok"`; Description string `json:"description"` }; if err := json.NewDecoder(resp.Body).Decode(&data); err != nil { return err }; if !data.OK { return fmt.Errorf("telegram setMyCommands failed: %s", data.Description) }; return nil
}
func (s *Server) getUpdates() ([]tgUpdate, error) { url := fmt.Sprintf("https://api.telegram.org/bot%s/getUpdates?timeout=25&offset=%d", s.cfg.BotToken, s.lastUpdID+1); resp, err := http.Get(url); if err != nil { return nil, err }; defer resp.Body.Close(); var data struct{ OK bool `json:"ok"`; Result []tgUpdate `json:"result"` }; if err := json.NewDecoder(resp.Body).Decode(&data); err != nil { return nil, err }; for _, u := range data.Result { if u.UpdateID > s.lastUpdID { s.lastUpdID = u.UpdateID } }; return data.Result, nil }

func (s *Server) handleTelegramUpdate(u tgUpdate) {
	if u.CallbackQuery != nil { s.handleCallbackEditable(u.CallbackQuery); return }
	if u.Message == nil || strings.TrimSpace(u.Message.Text) == "" { return }
	if u.Message.From.ID != s.cfg.AdminUserID { s.sendMessage(u.Message.Chat.ID, "Access denied"); return }
	chatID, text := u.Message.Chat.ID, strings.TrimSpace(u.Message.Text)
	if text == "/cancel" { wizardCancel(chatID); s.sendMessage(chatID, "Диалог отменён."); return }
	if s.handleWizardText(chatID, text) { return }
	switch {
	case text == "/start" || text == "/menu": s.sendMainMenu(chatID)
	case text == "/help": s.sendMessageWithKeyboard(chatID, helpText(), mainMenuKeyboard())
	case text == "/routers": s.sendMessageWithKeyboard(chatID, s.routerGroupsList(), s.routersKeyboardWithUpdateScripts())
	case strings.HasPrefix(text, "/add_router"): s.handleAddRouter(chatID, text)
	case strings.HasPrefix(text, "/results_"): s.sendMessage(chatID, s.results(strings.TrimPrefix(text, "/results_")))
	case strings.HasPrefix(text, "/set_primary_"): s.handleSetSource(chatID, text, "primary")
	case strings.HasPrefix(text, "/set_backup_"): s.handleSetSource(chatID, text, "backup")
	case strings.HasPrefix(text, "/"): s.handleCommand(chatID, text)
	default: s.sendMessageWithKeyboard(chatID, "Неизвестная команда. Нажми /menu или выбери действие.", mainMenuKeyboard())
	}
}

func (s *Server) handleCallback(cb *tgCallbackQuery) { s.handleCallbackEditable(cb) }
func (s *Server) sendMainMenu(chatID int64) { s.sendMessageWithKeyboard(chatID, prettyMainMenuText(), mainMenuKeyboard()) }
func mainMenuKeyboard() inlineKeyboard { return inlineKeyboard{InlineKeyboard: [][]inlineButton{{{Text:"📡 Роутеры", CallbackData:"routers"},{Text:"➕ Добавить роутер", CallbackData:"add_router_help"}},{{Text:"🔄 Обновить", CallbackData:"routers"},{Text:"❔ Помощь", CallbackData:"help"}}}} }
func (s *Server) routersKeyboard() inlineKeyboard { return s.routerGroupsKeyboard() }
func routerKeyboard(routerID string) inlineKeyboard { return inlineKeyboard{InlineKeyboard: [][]inlineButton{{{Text:"📊 Статус",CallbackData:"act:status:"+routerID},{Text:"🩺 Doctor",CallbackData:"act:doctor:"+routerID}},{{Text:"⬆️ Основной",CallbackData:"act:switch_primary:"+routerID},{Text:"⬇️ Резерв",CallbackData:"act:switch_backup:"+routerID}},{{Text:"🔗 Источники",CallbackData:"sources:"+routerID},{Text:"🧭 Маршруты",CallbackData:"routes:"+routerID}},{{Text:"🛡 Recovery status",CallbackData:"act:recover_status:"+routerID},{Text:"♻️ Recover now",CallbackData:"act:recover:"+routerID}},{{Text:"🕘 History",CallbackData:"act:history:"+routerID},{Text:"👁 Watchdog log",CallbackData:"act:watchdog:"+routerID},{Text:"🤖 Agent log",CallbackData:"act:agentlog:"+routerID}},{{Text:"📄 Recovery log",CallbackData:"act:recoverylog:"+routerID},{Text:"📬 Results",CallbackData:"act:results:"+routerID}},{{Text:"🔄 Скрипты",CallbackData:"act:update_scripts:"+routerID},{Text:"🔁 Агент",CallbackData:"act:update_agent:"+routerID}},{{Text:"🔄 Перезагрузить роутер",CallbackData:"act:reboot:"+routerID}},{{Text:"📦 Установка агента",CallbackData:"install:"+routerID}},{{Text:"🗑 Удалить роутер",CallbackData:"delete-router:"+routerID}},{{Text:"⬅️ Назад",CallbackData:"routers"},{Text:"🏠 Главное меню",CallbackData:"menu"}}}} }
func (s *Server) sendRouterMenu(chatID int64, routerID string) { text,kb,_ := s.routerMenuView(routerID); s.sendMessageWithKeyboard(chatID,text,kb) }
func (s *Server) handleActionCallback(chatID int64, messageID int, data string) { parts := strings.SplitN(data, ":", 3); if len(parts) != 3 { s.editOrSendMessageWithKeyboard(chatID,messageID,"Некорректная кнопка",mainMenuKeyboard()); return }; name, routerID := parts[1], parts[2]; if messageID > 0 { s.setActiveMenu(routerID, chatID, messageID) }; if name == "results" { s.editOrSendMessageWithKeyboard(chatID,messageID,s.results(routerID),s.currentRouterKeyboard(routerID)); return }; action := callbackAction(name); if action == "" { s.editOrSendMessageWithKeyboard(chatID,messageID,"Действие не поддерживается: "+name,routerKeyboard(routerID)); return }; id, err := s.enqueue(routerID, Command{Action: action}); if err != nil { s.editOrSendMessageWithKeyboard(chatID,messageID,err.Error(),s.routersKeyboard()); return }; s.editOrSendMessageWithKeyboard(chatID,messageID,s.routerMenuTextWithExtra(routerID,"⏳ Команда в очереди\n"+id),s.currentRouterKeyboard(routerID)) }
func callbackAction(name string) string { return map[string]string{"status":"status","doctor":"doctor","switch_primary":"switch_primary","switch_backup":"switch_backup","recover_status":"recover_status","recover_check":"recover_check","recover":"recover_run","recover_enable":"recover_enable","recover_disable":"recover_disable","history":"history","watchdog":"watchdog_log","agentlog":"agent_result_log","recoverylog":"recovery_log","source_status":"source_status","update_scripts":"update_scripts","update_agent":"update_agent","reboot":"reboot"}[name] }
func (s *Server) routerIDs() []string { s.mu.Lock(); defer s.mu.Unlock(); ids := make([]string,0,len(s.cfg.Routers)); for id := range s.cfg.Routers { ids = append(ids,id) }; sort.Strings(ids); return ids }
func (s *Server) handleCommand(chatID int64, text string) { name,routerID,ok := parseCmdRouter(text); if !ok { s.sendMessage(chatID,"Формат: /status_home или /doctor_home. Список: /routers"); return }; action := callbackAction(name); if action == "" { s.sendMessage(chatID,"Команда не поддерживается: "+name); return }; id,err := s.enqueue(routerID,Command{Action:action}); if err != nil { s.sendMessage(chatID,err.Error()); return }; s.sendMessage(chatID,"📨 Команда поставлена в очередь:\n"+id) }

func (s *Server) handleAddRouter(chatID int64, text string) { parts := strings.Fields(text); if len(parts) < 2 { s.sendMessageWithKeyboard(chatID,"Формат: /add_router <router_id> [имя]\nПример: /add_router dacha Дача",mainMenuKeyboard()); return }; routerID := parts[1]; if !validRouterID(routerID) { s.sendMessage(chatID,"router_id должен содержать только латинские буквы, цифры, _ или -. Пример: dacha"); return }; name := routerID; if len(parts) > 2 { name = strings.Join(parts[2:], " ") }; token,err := randomTokenHex(24); if err != nil { s.sendMessage(chatID,"Не удалось сгенерировать token: "+err.Error()); return }; s.mu.Lock(); if _,exists := s.cfg.Routers[routerID]; exists { s.mu.Unlock(); s.sendMessage(chatID,"Роутер уже существует: "+routerID); return }; s.cfg.Routers[routerID] = &Router{ID:routerID,Name:name,Token:token}; err = s.persistConfigLocked(); if err != nil { delete(s.cfg.Routers,routerID) }; s.mu.Unlock(); if err != nil { s.sendMessage(chatID,"Роутер не сохранён: "+err.Error()+"\nПроверь права: /etc/xray-go-control-server.conf должен быть writable для группы xraygo."); return }; s.sendMessageWithKeyboard(chatID,fmt.Sprintf("✅ Роутер добавлен\n\n📡 %s\nID: %s\n\nAgent token:\n%s\n\nОткрой меню роутера и нажми 📦 Установка агента.",name,routerID,token),routerKeyboard(routerID)) }
func (s *Server) handleSetSource(chatID int64, text, slot string) { prefix := "/set_"+slot+"_"; rest := strings.TrimPrefix(text,prefix); parts := strings.Fields(rest); if len(parts)<3 { s.sendMessage(chatID,"Формат: "+prefix+"<router> <selector> <url>"); return }; routerID:=parts[0]; selector:=normalizeSelector(parts[1]); source:=strings.Join(parts[2:]," "); action:="set_primary_source"; if slot=="backup" { action="set_backup_source" }; id,err:=s.enqueue(routerID,Command{Action:action,Selector:selector,Source:source}); if err!=nil { s.sendMessage(chatID,err.Error()); return }; extra:=fmt.Sprintf("⏳ Источник поставлен в очередь\n%s\n\nSlot: %s\nSelector: %s\nЗначение скрыто.", id, slot, selector); mid:=s.sendMessageWithKeyboardID(chatID,s.routerMenuTextWithExtra(routerID,extra),s.currentRouterKeyboard(routerID)); if mid!=0 { s.setActiveMenu(routerID,chatID,mid) } }
func parseCmdRouter(text string) (string,string,bool) { text = strings.TrimPrefix(strings.Fields(text)[0],"/"); idx := strings.LastIndex(text,"_"); if idx < 0 { return "","",false }; return text[:idx], text[idx+1:], true }
func (s *Server) enqueue(routerID string, c Command) (string,error) { s.mu.Lock(); defer s.mu.Unlock(); rt := s.cfg.Routers[routerID]; if rt == nil { return "", fmt.Errorf("unknown router: %s", routerID) }; c.ID = fmt.Sprintf("%s-%d", c.Action, time.Now().Unix()); rt.Queue = append(rt.Queue,c); return c.ID,nil }
func (s *Server) routerList() string { return s.routerGroupsList() }
func (s *Server) results(routerID string) string { s.mu.Lock(); defer s.mu.Unlock(); return prettyResults(s.cfg.Routers[routerID]) }
func (s *Server) setActiveMenu(routerID string, chatID int64, messageID int) { if routerID==""||chatID==0||messageID==0 { return }; s.mu.Lock(); if s.activeMenus==nil { s.activeMenus=map[string]ActiveMenu{} }; s.activeMenus[routerID]=ActiveMenu{ChatID:chatID,MessageID:messageID,RouterID:routerID}; s.mu.Unlock() }
func (s *Server) activeMenu(routerID string) (ActiveMenu,bool) { s.mu.Lock(); defer s.mu.Unlock(); m,ok:=s.activeMenus[routerID]; return m,ok }
func (s *Server) currentRouterKeyboard(routerID string) inlineKeyboard { s.mu.Lock(); rt:=s.cfg.Routers[routerID]; status:=""; if rt!=nil { status=rt.Status }; s.mu.Unlock(); return routerKeyboardForStatus(routerID,status) }
func (s *Server) routerMenuTextWithExtra(routerID, extra string) string { s.mu.Lock(); rt:=s.cfg.Routers[routerID]; card:=prettyRouterCard(rt); s.mu.Unlock(); if strings.TrimSpace(extra)=="" { return card }; return limit(card+"\n\n"+extra,3900) }
func (s *Server) editActiveRouterResult(routerID string, res Result) bool { active,ok:=s.activeMenu(routerID); if !ok { return false }; extra:="Последний ответ:\n"+prettyResultMessage("",res); return s.editMessageWithKeyboard(active.ChatID,active.MessageID,s.routerMenuTextWithExtra(routerID,extra),s.currentRouterKeyboard(routerID)) }
func (s *Server) sendMessage(chatID int64, text string) { s.sendMessageWithKeyboard(chatID,text,inlineKeyboard{}) }
func (s *Server) sendMessageWithKeyboard(chatID int64, text string, keyboard inlineKeyboard) { _ = s.sendMessageWithKeyboardID(chatID,text,keyboard) }
func (s *Server) sendMessageWithKeyboardID(chatID int64, text string, keyboard inlineKeyboard) int { if s.cfg.BotToken=="" { return 0 }; payload:=map[string]any{"chat_id":chatID,"text":limit(text,3900)}; if len(keyboard.InlineKeyboard)>0 { payload["reply_markup"]=keyboard }; body,_:=json.Marshal(payload); url:=fmt.Sprintf("https://api.telegram.org/bot%s/sendMessage",s.cfg.BotToken); resp,err:=http.Post(url,"application/json",bytes.NewReader(body)); if err!=nil { log.Printf("sendMessage: %v",err); return 0 }; defer resp.Body.Close(); b,_:=io.ReadAll(io.LimitReader(resp.Body,4096)); if resp.StatusCode<200||resp.StatusCode>=300 { log.Printf("sendMessage status=%s body=%s",resp.Status,string(b)); return 0 }; var data struct{ OK bool `json:"ok"`; Description string `json:"description"`; Result struct{ MessageID int `json:"message_id"` } `json:"result"` }; if err:=json.Unmarshal(b,&data); err!=nil { log.Printf("sendMessage decode: %v body=%s",err,string(b)); return 0 }; if !data.OK { log.Printf("sendMessage failed: %s",data.Description); return 0 }; return data.Result.MessageID }
func (s *Server) editMessageWithKeyboard(chatID int64, messageID int, text string, keyboard inlineKeyboard) bool { if s.cfg.BotToken==""||chatID==0||messageID==0 { return false }; payload:=map[string]any{"chat_id":chatID,"message_id":messageID,"text":limit(text,3900)}; if len(keyboard.InlineKeyboard)>0 { payload["reply_markup"]=keyboard }; body,_:=json.Marshal(payload); url:=fmt.Sprintf("https://api.telegram.org/bot%s/editMessageText",s.cfg.BotToken); resp,err:=http.Post(url,"application/json",bytes.NewReader(body)); if err!=nil { log.Printf("editMessageText: %v",err); return false }; defer resp.Body.Close(); b,_:=io.ReadAll(io.LimitReader(resp.Body,4096)); if resp.StatusCode<200||resp.StatusCode>=300 { if strings.Contains(string(b),"message is not modified") { return true }; log.Printf("editMessageText status=%s body=%s",resp.Status,string(b)); return false }; return true }
func (s *Server) answerCallback(callbackID, text string) { if s.cfg.BotToken==""||callbackID=="" { return }; payload:=map[string]any{"callback_query_id":callbackID}; if text!="" { payload["text"]=text }; body,_:=json.Marshal(payload); url:=fmt.Sprintf("https://api.telegram.org/bot%s/answerCallbackQuery",s.cfg.BotToken); resp,err:=http.Post(url,"application/json",bytes.NewReader(body)); if err!=nil { log.Printf("answerCallback: %v",err); return }; _,_=io.Copy(io.Discard,resp.Body); _=resp.Body.Close() }

func helpText() string { return strings.TrimSpace(`❔ Помощь

Основные команды:
/menu — главное меню
/routers — список роутеров
/add_router <router_id> [имя]

Быстрые команды:
/status_<router>
/doctor_<router>
/switch_primary_<router>
/switch_backup_<router>
/recover_status_<router>
/recover_check_<router>
/recover_<router>
/recover_enable_<router>
/recover_disable_<router>
/history_<router>
/watchdog_<router>
/recoverylog_<router>
/source_status_<router>
/results_<router>

Источники:
/set_primary_<router> <selector> <url>
/set_backup_<router> <selector> <url>`) }
func loadConfig(path string) (Config,error) { cfg:=Config{ConfigPath:path,Listen:":18090",Routers:map[string]*Router{}}; data,err:=os.ReadFile(path); if err!=nil { return cfg,err }; vals:=map[string]string{}; for _,line:=range strings.Split(string(data),"\n") { line=strings.TrimSpace(line); if line==""||strings.HasPrefix(line,"#") { continue }; k,v,ok:=strings.Cut(line,"="); if !ok { continue }; vals[strings.TrimSpace(k)]=strings.Trim(strings.TrimSpace(v),"\"") }; if vals["LISTEN"]!="" { cfg.Listen=vals["LISTEN"] }; cfg.BotToken=vals["BOT_TOKEN"]; if vals["ADMIN_USER_ID"]!="" { cfg.AdminUserID,_=strconv.ParseInt(vals["ADMIN_USER_ID"],10,64) }; cfg.Groups=parseRouterGroupNames(vals["ROUTER_GROUP_NAMES"]); groups:=parseRouterGroupAssignments(vals["ROUTER_GROUPS"]); for _,item:=range strings.Split(vals["ROUTERS"],",") { parts:=strings.SplitN(strings.TrimSpace(item),":",3); if len(parts)<2 { continue }; name:=parts[0]; if len(parts)==3 { name=parts[2] }; cfg.Routers[parts[0]]=&Router{ID:parts[0],Token:parts[1],Name:name,Group:groups[parts[0]]}; if groups[parts[0]]!="" { seen:=false; for _,g:=range cfg.Groups { if g==groups[parts[0]] { seen=true; break } }; if !seen { cfg.Groups=append(cfg.Groups,groups[parts[0]]) } } }; if cfg.BotToken==""||cfg.AdminUserID==0 { return cfg,fmt.Errorf("BOT_TOKEN and ADMIN_USER_ID are required") }; if len(cfg.Routers)==0 { return cfg,fmt.Errorf("ROUTERS is required") }; return cfg,nil }
func (s *Server) persistConfigLocked() error { ids:=make([]string,0,len(s.cfg.Routers)); for id:=range s.cfg.Routers { ids=append(ids,id) }; sort.Strings(ids); items:=make([]string,0,len(ids)); for _,id:=range ids { r:=s.cfg.Routers[id]; items=append(items,r.ID+":"+r.Token+":"+r.Name) }; routerGroups:=formatRouterGroupAssignments(s.cfg.Routers); groupNames:=formatRouterGroupNames(s.cfg.Groups); content:=fmt.Sprintf("LISTEN=\"%s\"\nBOT_TOKEN=\"%s\"\nADMIN_USER_ID=\"%d\"\nROUTERS=\"%s\"\nROUTER_GROUPS=\"%s\"\nROUTER_GROUP_NAMES=\"%s\"\n",s.cfg.Listen,s.cfg.BotToken,s.cfg.AdminUserID,strings.Join(items,","),routerGroups,groupNames); return os.WriteFile(s.cfg.ConfigPath,[]byte(content),0660) }
func compactStatus(status string) string { status=strings.TrimSpace(status); if status=="" { return "нет heartbeat" }; seen:=map[string]bool{}; out:=[]string{}; for _,part:=range strings.Split(status,";") { p:=strings.TrimSpace(part); if p==""||seen[p] { continue }; seen[p]=true; out=append(out,p) }; if len(out)==0 { return status }; return strings.Join(out,"; ") }
func validRouterID(id string) bool { if id=="" { return false }; for _,r:=range id { if (r>='a'&&r<='z')||(r>='A'&&r<='Z')||(r>='0'&&r<='9')||r=='_'||r=='-' { continue }; return false }; return true }
func randomTokenHex(n int) (string,error) { b:=make([]byte,n); _,err:=rand.Read(b); if err!=nil { return "",err }; return hex.EncodeToString(b),nil }
func limit(s string,n int) string { if len(s)<=n { return s }; return s[:n]+"\n...truncated..." }
