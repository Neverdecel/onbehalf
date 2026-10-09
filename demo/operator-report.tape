# Operator cast, after the user cast: the model use of each user and the
# health of the host.
Output operator-report.gif
Output operator-report.webm
Source "/demo/settings.tape"
# The report table is wide.
Set FontSize 18
Source "/demo/prompt.tape"

Type "ssh ops@devbox"
Enter
Wait /ops@devbox:~[$]$/
Sleep 1s

Type "clear && sudo onbehalf report"
Enter
Wait /ops@devbox:~[$]$/
Sleep 8s

Type "clear && sudo onbehalf health"
Enter
Wait /ops@devbox:~[$]$/
Sleep 5s
