# Operator cast: install onbehalf on a host, connect the gateway, install the
# shared stack and add two users. Each step has its own screen.
Output operator-setup.gif
Output operator-setup.webm
Source "/demo/settings.tape"
Source "/demo/prompt.tape"

Type "ssh ops@devbox"
Enter
Wait /ops@devbox/
Sleep 500ms

Type "cd onbehalf && sudo ./install.sh"
Enter
Wait /ops@devbox:~.onbehalf[$]$/
Sleep 3s

# The admin key of the gateway is in a file of ops (see entrypoint.sh).
Type "clear && sudo onbehalf init --gateway-url http://gateway:4000 <~/admin.key"
Enter
Wait /ops@devbox:~.onbehalf[$]$/
Sleep 4s

Type "clear && sudo onbehalf stack install examples/stack"
Enter
Wait /ops@devbox:~.onbehalf[$]$/
Sleep 4s

Type "clear && sudo onbehalf user add alice bob"
Enter
Wait /ops@devbox:~.onbehalf[$]$/
Sleep 6s
