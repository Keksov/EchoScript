/**
 * Native OS path picker (CP — jobs_root full-path selection). The browser can't expose an
 * absolute filesystem path (webkitdirectory / showDirectoryPicker are sandboxed), but the
 * control-server runs locally, so we pop the standard Windows dialog via PowerShell (-STA for
 * WinForms) and return the chosen absolute path. Blocks until the user picks or cancels.
 */
export type PickerKind = "directory" | "file"

const psEscape = (value: string): string => value.replace(/'/gu, "''")

const folderScript = (start: string): string => `
Add-Type -AssemblyName System.Windows.Forms | Out-Null
$owner = New-Object System.Windows.Forms.Form
$owner.TopMost = $true
$d = New-Object System.Windows.Forms.FolderBrowserDialog
$d.Description = 'EchoScript'
$d.ShowNewFolderButton = $true
$start = '${psEscape(start)}'
if ($start -and (Test-Path -LiteralPath $start)) { $d.SelectedPath = $start }
if ($d.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { [Console]::Out.Write($d.SelectedPath) }
`

const fileScript = (start: string): string => `
Add-Type -AssemblyName System.Windows.Forms | Out-Null
$owner = New-Object System.Windows.Forms.Form
$owner.TopMost = $true
$d = New-Object System.Windows.Forms.OpenFileDialog
$start = '${psEscape(start)}'
if ($start) {
  $dir = Split-Path -Parent $start
  if ($dir -and (Test-Path -LiteralPath $dir)) { $d.InitialDirectory = $dir }
  $d.FileName = Split-Path -Leaf $start
}
if ($d.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { [Console]::Out.Write($d.FileName) }
`

export const pickPath = async (
  kind: PickerKind,
  start: string,
): Promise<{ path: string | null; cancelled: boolean }> => {
  const script = kind === "directory" ? folderScript(start) : fileScript(start)
  const proc = Bun.spawn(["powershell.exe", "-STA", "-NoProfile", "-Command", script], {
    stdout: "pipe",
    stderr: "ignore",
  })
  const output = (await new Response(proc.stdout).text()).trim()
  await proc.exited
  return output.length > 0 ? { path: output, cancelled: false } : { path: null, cancelled: true }
}
