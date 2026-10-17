[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][ValidateSet('A','B')][string]$HostLabel,
 [Parameter(Mandatory=$true)][string]$CandidateDir
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

# User's running desktop must never receive staged files or process kills.
if($PSVersionTable.PSEdition -cne 'Desktop' -or
   $env:GITHUB_ACTIONS -cne 'true' -or
   $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
   $env:RUNNER_OS -cne 'Windows' -or
   $env:COMPUTERNAME -match '(?i)EMAD-PC' -or
   [string]::IsNullOrWhiteSpace($env:GITHUB_SHA) -or
   [string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID) -or
   [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)){
 throw 'R302_ONLY_FRESH_GITHUB_HOSTED_WINDOWS_GUEST'
}

function SHA([string]$path){
 if(!(Test-Path -LiteralPath $path -PathType Leaf)){return 'MISSING'}
 return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}
$repo='GOD13emad/TaskbarMonitorEnhanced'
$app=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'TaskbarMonitorEnhanced'
$stage=Join-Path $app '.tbme-upgrade'
$retired=Join-Path $app '.tbme-upgrade-retired'
$setup=Join-Path $CandidateDir 'Setup\TaskbarMonitorEnhanced_Setup_1.7.8.exe'
$manifest=Join-Path $CandidateDir 'CANDIDATE.json'
$prior=Join-Path $env:RUNNER_TEMP ('R301_'+$HostLabel+'_'+$env:GITHUB_RUN_ID+'\R301_ROLLBACK_RETRY_RECEIPT.json')
$root=Join-Path $env:RUNNER_TEMP ('R302_'+$HostLabel+'_'+$env:GITHUB_RUN_ID)
$receipt=Join-Path $root 'R302_REAL_SETUP_CLEANUP_KILL_RECEIPT.json'
$registry='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\TaskbarMonitorEnhanced'
$program=Join-Path $app 'TaskbarMonitorEnhanced.exe'
$config=Join-Path $app 'config.json'
$backupConfig=Join-Path $app 'config.json.bak'
$userState=Join-Path $app 'install_state.json'
$setupInstalled=Join-Path $app 'Uninstall.exe'
$native=$null;$retry=$null;$watcher=$null
$phase='INITIAL';$accepted=$false;$failure=''
$checks=[Collections.Generic.List[string]]::new()
if((Test-Path -LiteralPath $stage) -or (Test-Path -LiteralPath $retired) -or
   (Test-Path -LiteralPath $root) -or
   @(Get-Process TaskbarMonitorEnhanced -ErrorAction SilentlyContinue).Count -ne 0){
 throw 'R302_GUEST_HAS_UNEXPECTED_JOURNAL_OR_RUNNING_MAIN'
}
[void][IO.Directory]::CreateDirectory($root)
$source=Get-Content -LiteralPath $manifest -Raw|ConvertFrom-Json
$previous=Get-Content -LiteralPath $prior -Raw|ConvertFrom-Json
if($source.Commit -cne $env:GITHUB_SHA -or
   $source.SetupSHA256 -cne (SHA $setup) -or
   $source.MainSHA256 -cne (SHA $program) -or
   $previous.Host -cne $HostLabel -or
   $previous.SourceCommit -cne $env:GITHUB_SHA -or
   $previous.Status -cne 'PASS_ROLLED_BACK_JOURNAL_RETRY_REAL_WORKER_TERMINATION'){
 throw 'R302_SOURCE_OR_PREDECESSOR_RECEIPT_UNVERIFIED'
}
$before=[ordered]@{}
foreach($file in @($program,$config,$backupConfig,$userState,$setupInstalled)){
 $before[$file]=SHA $file
}
if($before[$setupInstalled] -cne $source.SetupSHA256){
 throw 'R302_INSTALLED_GUEST_SETUP_NOT_EXACT_CANDIDATE'
}
$display=[string](Get-ItemProperty -LiteralPath $registry -ErrorAction Stop).DisplayVersion
if($display -cne '1.7.8'){throw 'R302_GUEST_INSTALLED_VERSION_NOT_MATCHED'}
$checks.Add('GUEST_MAIN_SETUP_CONFIG_STATE_AND_REGISTRY_PINNED')

# .NET Framework 4.8 compatibility: callback kills exactly the Process object
# started below. No process-name search and no host-wide/process-tree kill.
$sourceCode=@'
using System;
using System.IO;
using System.Diagnostics;
using System.Threading;
public sealed class R302RealSetupDeleteWatcher : IDisposable {
  public readonly ManualResetEventSlim TerminatedEvent = new ManualResetEventSlim(false);
  private FileSystemWatcher oldWatcher, newWatcher;
  private Process child;
  private int once, notifications;
  public string TriggerFile = "";
  public string Failure = "";
  public bool Killed = false;
  public int Notifications { get { return notifications; } }
  public void Arm(string oldPath, string newPath) {
    oldWatcher = Make(oldPath);
    newWatcher = Make(newPath);
    oldWatcher.EnableRaisingEvents=true;
    newWatcher.EnableRaisingEvents=true;
  }
  private FileSystemWatcher Make(string path) {
    FileSystemWatcher watcher = new FileSystemWatcher(path);
    watcher.IncludeSubdirectories=true;
    watcher.Filter="*";
    watcher.NotifyFilter=NotifyFilters.FileName | NotifyFilters.DirectoryName;
    watcher.InternalBufferSize=32768;
    watcher.Deleted += OnDeleted;
    return watcher;
  }
  public void Bind(Process p) {
    Interlocked.Exchange(ref child, p);
  }
  private void OnDeleted(object sender, FileSystemEventArgs e) {
    Interlocked.Increment(ref notifications);
    string path=e.FullPath;
    string extension=Path.GetExtension(path).ToLowerInvariant();
    // A known leaf deletion, not a directory deletion or metadata preflight.
    if(extension!=".exe" && extension!=".cs" && extension!=".md" &&
       extension!=".json" && extension!=".config" && extension!=".ico") return;
    if(Interlocked.CompareExchange(ref once,1,0)!=0) return;
    TriggerFile=Path.GetFileName(path);
    try {
      Process process=child;
      if(process==null) throw new Exception("PROCESS_NOT_BOUND");
      process.Refresh();
      if(process.HasExited) throw new Exception("SETUP_ALREADY_EXITED");
      process.Kill();
      Killed=process.WaitForExit(10000) && process.HasExited && process.ExitCode!=0;
      if(!Killed) Failure="SETUP_KILL_NOT_CONFIRMED";
    }catch(Exception error){Failure=error.GetType().Name+":"+error.Message;}
    finally{TerminatedEvent.Set();}
  }
  public void Dispose(){
    if(oldWatcher!=null){oldWatcher.EnableRaisingEvents=false;oldWatcher.Dispose();}
    if(newWatcher!=null){newWatcher.EnableRaisingEvents=false;newWatcher.Dispose();}
  }
}
'@
Add-Type -TypeDefinition $sourceCode -ErrorAction Stop

# Build a genuine ROLLED_BACK journal; hashes are from the live disposable
# installed guest. Stage payload files are disposable and exactly named by
# the candidate's compiled inventory, never unknown owner data.
$assembly=[Reflection.Assembly]::LoadFile([IO.Path]::GetFullPath($setup))
$type=$assembly.GetType('SetupProgram',$true)
$static=[Reflection.BindingFlags]'Static,NonPublic'
$instance=[Reflection.BindingFlags]'Instance,NonPublic,Public'
$field=$type.GetField('UpgradeTargets',$static)
if(!$field){throw 'R302_COMPILED_TARGET_INVENTORY_MISSING'}
$targets=[array]$field.GetValue($null)
if($targets.Count -lt 25 -or $targets.Count -gt 40){throw 'R302_UNEXPECTED_TARGET_COUNT'}
$lines=[Collections.Generic.List[string]]::new()
$staged=0
$old=Join-Path $stage 'old'
$new=Join-Path $stage 'new'
[void][IO.Directory]::CreateDirectory($old)
[void][IO.Directory]::CreateDirectory($new)
foreach($target in $targets){
 $relField=$target.GetType().GetField('Rel',$instance)
 if(!$relField){throw 'R302_TARGET_REL_FIELD_MISSING'}
 $rel=[string]$relField.GetValue($target)
 if(!$rel -or $rel -match '(^|[/\\])\.\.([/\\]|$)' -or
    [IO.Path]::IsPathRooted($rel) -or $rel -match '[:*?"<>|]'){
   throw 'R302_UNSAFE_COMPILED_TARGET'
 }
 $live=Join-Path $app ($rel.Replace('/',[IO.Path]::DirectorySeparatorChar))
 $prev=SHA $live
 if($prev -ceq 'MISSING'){$prev='-'}
 if($prev -cne '-' -and $prev -cnotmatch '^[A-F0-9]{64}$'){
  throw 'R302_BAD_PINNED_PREVIOUS_DIGEST'
 }
 $lines.Add($rel+'|'+$prev+'|-')
 foreach($part in @($old,$new)){
  $name=Join-Path $part ($rel.Replace('/',[IO.Path]::DirectorySeparatorChar))
  $parent=[IO.Path]::GetDirectoryName($name)
  [void][IO.Directory]::CreateDirectory($parent)
  [IO.File]::WriteAllText($name,('R302_STAGE_ONLY_'+$HostLabel+'_'+$rel),[Text.UTF8Encoding]::new($false))
  $staged++
 }
}
if($staged -ne ($targets.Count*2)){throw 'R302_STAGE_FIXTURE_COUNT_INCORRECT'}
$marker='TBME_UPGRADE_R92_OWNED_STAGE_V1'
[IO.File]::WriteAllText((Join-Path $stage 'owner.txt'),$marker,[Text.Encoding]::ASCII)
[IO.File]::WriteAllText((Join-Path $stage 'index.txt'),
 ($lines.ToArray() -join ([string][char]10)),[Text.Encoding]::ASCII)
[IO.File]::WriteAllText((Join-Path $stage 'previous_version.txt'),'1.7.8',[Text.Encoding]::ASCII)
[IO.File]::WriteAllText((Join-Path $stage 'phase.txt'),($marker+'|ROLLED_BACK'),[Text.Encoding]::ASCII)
$checks.Add('COMPLETE_PINNED_ROLLED_BACK_JOURNAL_WITH_KNOWN_STAGE_PAYLOADS')

try {
 $phase='START_EXACT_ORIGINAL_SETUP_AND_ARM_DELETE_WATCH'
 $watcher=[R302RealSetupDeleteWatcher]::new()
 $watcher.Arm($old,$new)
 $psi=[Diagnostics.ProcessStartInfo]::new()
 $psi.FileName=$setup
 $psi.Arguments='/update /quiet'
 $psi.UseShellExecute=$false
 $psi.CreateNoWindow=$true
 $psi.WorkingDirectory=[IO.Path]::GetDirectoryName($setup)
 $native=[Diagnostics.Process]::Start($psi)
 if(!$native){throw 'R302_ORIGINAL_SETUP_FAILED_TO_START'}
 $realSetupPid=$native.Id
 $watcher.Bind($native)
 $clock=[Diagnostics.Stopwatch]::StartNew()
 while(-not $watcher.TerminatedEvent.Wait(75) -and $clock.ElapsedMilliseconds -lt 45000){
  $native.Refresh()
  if($native.HasExited){break}
 }
 $native.Refresh()
 if(!$watcher.Killed){
  throw ('R302_SETUP_NOT_KILLED_ON_A_KNOWN_STAGE_FILE_DELETE; cause='+
     $watcher.Failure+' events='+$watcher.Notifications+
     ' setupExited='+$native.HasExited)
 }
 if(!$native.HasExited -or $native.ExitCode -eq 0){
  throw 'R302_ACTUAL_SETUP_PID_TERMINATION_NOT_PROVEN'
 }
 $checks.Add('REAL_ORIGINAL_SETUP_PID_KILLED_BY_NATIVE_FILE_DELETION_EVENT')
 $activeRemaining=@(Get-ChildItem $stage -Recurse -File -ErrorAction SilentlyContinue).Count
 $retiredRemaining=@(Get-ChildItem $retired -Recurse -File -ErrorAction SilentlyContinue).Count
 if(($activeRemaining+$retiredRemaining) -le 0 -or
    (!(Test-Path $stage) -and !(Test-Path $retired))){
  throw 'R302_NO_PARTIAL_JOURNAL_WITNESS_AFTER_SETUP_KILL'
 }
 $checks.Add('SOME_RECOVERABLE_STAGE_METADATA_SURVIVES_ACTUAL_SETUP_KILL')
 $phase='COLD_RETRY_EXACT_ORIGINAL_SETUP'
 $retry=[Diagnostics.Process]::Start($psi)
 if(!$retry){throw 'R302_COLD_RESTART_SETUP_NOT_LAUNCHED'}
 $retryPid=$retry.Id
 if(!$retry.WaitForExit(90000)){
  $retry.Kill();[void]$retry.WaitForExit(9000)
  throw 'R302_COLD_RETRY_EXCEEDED_BOUNDED_BUDGET'
 }
 if($retry.ExitCode -ne 0){
  throw ('R302_NATIVE_SETUP_RECOVERY_NONZERO_'+$retry.ExitCode)
 }
 if((Test-Path $stage) -or (Test-Path $retired)){
  throw 'R302_RECOVERY_DID_NOT_CLEAR_BOTH_JOURNAL_NAMES'
 }
 $checks.Add('EXACT_SAME_BINARY_RESTART_RETIRES_PARTIAL_JOURNAL')
 foreach($path in $before.Keys){
  if((SHA $path) -cne $before[$path]){
   throw ('R302_GUEST_DATA_BINARY_OR_SETTING_CHANGED_'+$path)
  }
 }
 if([string](Get-ItemProperty -LiteralPath $registry).DisplayVersion -cne $display){
  throw 'R302_HKCU_INSTALLED_VERSION_CHANGED'
 }
 if(@(Get-Process TaskbarMonitorEnhanced -ErrorAction SilentlyContinue).Count -ne 0){
  throw 'R302_UNEXPECTED_BACKGROUND_APP_STARTED'
 }
 $checks.Add('BYTE_EXACT_SETUP_MAIN_USER_SETTINGS_AND_REGISTRY_PRESERVED')
 $data=[ordered]@{
  Schema=1;Revision='R302';Status='PASS_NATIVE_SETUP_KILLED_DURING_STAGE_CLEANUP_RECOVERED'
  Host=$HostLabel;SourceCommit=$env:GITHUB_SHA
  OriginalOwnerComputerTouched=$false;UnmodifiedCandidateSetupExecuted=$true
  ActualSetupPid=$realSetupPid;ActualSetupProcessTerminated=$true
  DeletedStageFileTrigger=$watcher.TriggerFile
  FileDeletionNotifications=$watcher.Notifications
  JournalFilesAfterKill=($activeRemaining+$retiredRemaining)
  RecoveredBySecondActualSetupProcess=$true;SecondSetupPid=$retryPid
  MainSetupConfigStateAndRegistryPreserved=$true
  NoStageOrRetiredResidue=$true
  CurrentVersion='1.7.8';Tests=@($checks)
  RecordedUtc=[DateTime]::UtcNow.ToString('o')
 }
 [IO.File]::WriteAllText($receipt,($data|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
 $accepted=$true
 'R302_'+$HostLabel+'_EXACT_UNMODIFIED_SETUP_KILL_AND_RESTART_PASS'
}catch{
 $failure=$_.Exception.ToString()
 throw
}finally{
 if($watcher){$watcher.Dispose()}
 foreach($process in @($native,$retry)){
  if($null -ne $process){
   try{
    $process.Refresh()
    if(!$process.HasExited){
     $process.Kill()
     [void]$process.WaitForExit(10000)
    }
   }finally{$process.Dispose()}
  }
 }
 if(!$accepted){
  $bad=[ordered]@{
   Schema=1;Revision='R302';Status='FAIL_NOT_ACCEPTED'
   Host=$HostLabel;SourceCommit=$env:GITHUB_SHA
   Phase=$phase;Failure=$failure
   OriginalOwnerComputerTouched=$false
   RecordedUtc=[DateTime]::UtcNow.ToString('o')
  }
  [IO.File]::WriteAllText($receipt,($bad|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
 }
}
