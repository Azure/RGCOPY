## Version history
#### RGCOPY 0.9.26
type|change
:---|:---
bug fix| error `Snapshot xxx not found. Remove parameter skipSnapshots` <BR>add snapshots to white list

#### RGCOPY 0.9.28
type|change
:---|:---
feature|Add new variables for scripts that were started from RGCOPY: <BR>`vmSize<vmName>`, `vmCpus<vmName>`, `vmMemGb<vmName>`
UI|Check that provided ARM template has been created by RGCOPY:<BR>change misleading error message `Invalid ARM template`
feature|Check status and version of VM Agent (parameter `vmAgentWaitMinutes`)<BR>wait for VM Agent start rather than VM start before executing Invoke-AzVMRunCommand.
UI|In case of errors of `Invoke-AzVMRunCommand`: output of error message rather than exception<BR>use cmdlet parameter ErrorAction = 'SilentlyContinue'
VS Code|Avoid VS Code warning: convert non-breaking spaces to spaces
VS Code|Avoid wrong VS Code warning: The variable 'hasIP' is assigned but never used.
bug fix|Error `Invalid data type, the rule is not a string` while parsing parameters:<BR>allow [char] in addition to [string]
etc|New function convertTo-array that ensures data type [array]
feature|Wait for VM services to be started (parameter `vmStartWaitSec`)
bug fix|RGCOPY VM tags for remotely running scripts not working<BR>(`rgcopy.ScriptStartSap`, `rgcopy.ScriptStartLoad`, `rgcopy.ScriptStartAnalysis`)
