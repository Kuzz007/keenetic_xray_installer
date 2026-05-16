package main

func (s *Server) editOrSendMessageWithKeyboard(chatID int64, messageID int, text string, keyboard inlineKeyboard) {
	if messageID > 0 && s.editMessageWithKeyboard(chatID, messageID, text, keyboard) {
		return
	}
	s.sendMessageWithKeyboard(chatID, text, keyboard)
}
