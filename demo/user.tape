# User cast: the first SSH login, the guided set-up of Git and GitHub, and a
# run of the AI harness that acts as the user.
Output user.gif
Output user.webm
Source "/demo/settings.tape"
Source "/demo/prompt.tape"

Type "ssh alice@devbox"
Enter
Wait+Screen /Skip for now/
Sleep 3s

# All tools are selected. Clear Azure CLI, go to "Continue" and confirm.
Down
Sleep 300ms
Down
Sleep 300ms
Space
Sleep 600ms
Down
Sleep 300ms
Enter
Wait /Name/
Sleep 1s
Type "Alice Example"
Enter
Wait /Email/
Type "alice@example.com"
Enter
Wait /press Enter/
Sleep 2s
Enter
Wait /alice@devbox:~[$]$/
Sleep 3s

# The fake model of the demo runs the command after "RUN:" as a tool call.
Hide
Type "clear && mkdir -p ~/project && cd ~/project && git init -q && clear"
Enter
Wait /alice@devbox:~.project[$]$/
Show
Type `opencode run --auto 'RUN: whoami && git commit --allow-empty -qm Draft && git log -1 --format="%an <%ae>"'`
Enter
Wait /alice@devbox:~.project[$]$/
Sleep 8s
