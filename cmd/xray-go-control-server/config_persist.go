package main

import (
	"fmt"
	"os"
	"sort"
	"strings"
)

func (s *Server) persistConfigLocked() error {
	ids := make([]string, 0, len(s.cfg.Routers))
	for id := range s.cfg.Routers {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	items := make([]string, 0, len(ids))
	for _, id := range ids {
		r := s.cfg.Routers[id]
		items = append(items, r.ID+":"+r.Token+":"+r.Name)
	}
	legacyHTTP := "0"
	if s.cfg.AllowLegacyHTTP {
		legacyHTTP = "1"
	}
	content := fmt.Sprintf(
		"LISTEN=\"%s\"\nALLOW_LEGACY_HTTP=\"%s\"\nBOT_TOKEN=\"%s\"\nADMIN_USER_ID=\"%d\"\nROUTERS=\"%s\"\nCERT_FILE=\"%s\"\nKEY_FILE=\"%s\"\nSTATE_FILE=\"%s\"\n",
		s.cfg.Listen,
		legacyHTTP,
		s.cfg.BotToken,
		s.cfg.AdminUserID,
		strings.Join(items, ","),
		s.cfg.CertFile,
		s.cfg.KeyFile,
		s.cfg.StateFile,
	)
	return os.WriteFile(s.cfg.ConfigPath, []byte(content), 0660)
}
