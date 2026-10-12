-- Rename this Mac: opens the rename-mac window.
-- The script itself ships inside the app at Contents/Resources/rename-mac.

on run
	set tool to POSIX path of (path to resource "rename-mac")
	set flag to (POSIX path of (path to home folder)) & ".rename-mac/app-offered-cli"

	-- First launch only: offer the Terminal command too.
	if (do shell script "test -e " & quoted form of flag & " && echo yes || echo no") is "no" then
		do shell script "mkdir -p ~/.rename-mac && touch " & quoted form of flag
		set answer to button returned of (display dialog "Also add the rename-mac command for Terminal?" & return & return & "It goes in ~/.local/bin (or /usr/local/bin) with Tab completion, and adds a few lines to ~/.zshrc. You can skip this and still use this app." with title "Rename this Mac" buttons {"Not now", "Add command"} default button "Add command" with icon note)
		if answer is "Add command" then
			try
				do shell script "/bin/zsh " & quoted form of tool & " --install-cli --yes"
				display dialog "Added. Open a new Terminal window and run: rename-mac --show" with title "Rename this Mac" buttons {"OK"} default button "OK" with icon note
			on error errText
				display alert "Couldn't add the Terminal command" message errText as warning
			end try
		end if
	end if

	try
		do shell script "/bin/zsh " & quoted form of tool & " --gui"
	end try
end run
