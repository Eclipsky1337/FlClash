package core

import "github.com/metacubex/mihomo/hub/auth"

func handleGetAuthListen() string {
	return auth.Listen()
}
