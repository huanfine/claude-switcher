# Windows 报告 v2 的真实 PowerShell 集成测试
#
# 只用临时 USERPROFILE / APPDATA / LOCALAPPDATA 和本地文本夹具，不联网、不读真实账号。
# 在 Windows PowerShell 5.1 或 pwsh 7 下运行：
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\windows-report-integration.ps1
#
# 覆盖：report 命令退出码 / schema / 16 个稳定 ID / 缺失项 / 指纹 / 重复项 /
# 全 skip / 缺关键项 / 未知项。checkdetail --json 的接线由静态契约测试覆盖。

$ErrorActionPreference = 'Stop'
# 子进程按 UTF-8 输出中文 JSON;父进程也必须按 UTF-8 解码,否则中文断言在
# 非 UTF-8 代码页的 Windows 上会变成乱码。
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$repoRoot = Split-Path -Parent $PSScriptRoot
$core = Join-Path (Join-Path $repoRoot 'windows') 'claude-switch.ps1'
if (-not (Test-Path -LiteralPath $core)) { throw "找不到核心脚本: $core" }

$root = Join-Path ([IO.Path]::GetTempPath()) ('cs-report-it-' + [guid]::NewGuid().ToString('N'))
$savedEnv = @{}
$envNames = @('USERPROFILE', 'APPDATA', 'LOCALAPPDATA')
foreach ($name in $envNames) {
    $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    $path = Join-Path $root $name
    [Environment]::SetEnvironmentVariable($name, $path, 'Process')
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

$base = Join-Path $env:USERPROFILE '.claude-switcher'
New-Item -ItemType Directory -Path $base -Force | Out-Null
$exe = if ($PSVersionTable.PSEdition -eq 'Core') {
    if ($IsWindows) { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'pwsh' }
} else {
    Join-Path $PSHOME 'powershell.exe'
}
$script:failures = 0

function Assert([string]$what, [bool]$condition, [string]$detail = '') {
    if ($condition) {
        "PASS  $what"
    } else {
        "FAIL  $what $detail"
        $script:failures++
    }
}

function Write-Fixture([string]$path, [string[]]$lines) {
    [IO.File]::WriteAllLines($path, [string[]]$lines, [Text.UTF8Encoding]::new($false))
}

function New-CheckLines([string]$state = 'ok') {
    return @(
        '# 2026-11-14 12:00:00 pid=1 开始',
        "代理内核=${state}:Clash Verge 运行中",
        "TUN网卡=$state",
        "出口IP=${state}:203.0.113.10",
        "IP一致=${state}:身份未变化",
        "时区=$state",
        "地区=$state",
        "IPv6=$state",
        "DNS=$state",
        "WebRTC=$state",
        "保镖=$state",
        "规则置顶=$state",
        "客户端语言=$state",
        "ASN属性=$state",
        "生态可达性=$state",
        '# 结束'
    )
}

function Invoke-Report([string[]]$reportArgs) {
    $output = & $exe -NoProfile -ExecutionPolicy Bypass -File $core @reportArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "report 失败($LASTEXITCODE): $($output -join "`n")"
    }
    return ((($output | ForEach-Object { [string]$_ }) -join "`n") | ConvertFrom-Json)
}

function Set-CheckConfig([string]$json) {
    [IO.File]::WriteAllText((Join-Path $base 'checks.json'), $json, [Text.UTF8Encoding]::new($false))
}

try {
    Set-Content -LiteralPath (Join-Path $base 'version.txt') -Value '9.9.9-report-test' -Encoding UTF8 -NoNewline
    Set-CheckConfig '{"disabled":["DNS"],"allowOptionalFailures":false,"logging":true}'

    $fixture = Join-Path $root 'report.txt'
    Write-Fixture $fixture (New-CheckLines)
    $doc = Invoke-Report @('report', $fixture)

    Assert 'schema 为 claude-switcher-report/2' ($doc.schema -eq 'claude-switcher-report/2') "实际=$($doc.schema)"
    Assert 'protocol 为 2' ([int]$doc.protocol -eq 2) "实际=$($doc.protocol)"
    Assert 'platform 为 Windows' ($doc.platform -eq 'Windows') "实际=$($doc.platform)"
    Assert 'version.txt 被读入 core_version' ($doc.core_version -eq '9.9.9-report-test') "实际=$($doc.core_version)"
    Assert '14 项检查全部保留' (@($doc.checks).Count -eq 14) "实际=$(@($doc.checks).Count)"
    Assert 'expected 保留 16 个稳定 ID' ([int]$doc.summary.expected -eq 16) "实际=$($doc.summary.expected)"
    Assert 'total 为实际 14 项' ([int]$doc.summary.total -eq 14) "实际=$($doc.summary.total)"
    Assert 'passed 为 14' ([int]$doc.summary.passed -eq 14) "实际=$($doc.summary.passed)"
    Assert 'missing 精确为 IP纯净度/更优节点' ((@($doc.summary.missing) -join ',') -eq 'IP纯净度,更优节点') "实际=$(@($doc.summary.missing) -join ',')"
    Assert 'missing_critical 为空' (@($doc.summary.missing_critical).Count -eq 0) "实际=$(@($doc.summary.missing_critical) -join ',')"
    Assert 'established 不因两个可选缺失项降级' ($doc.verdict -eq 'established') "实际=$($doc.verdict)"
    Assert '第一项是 proxy_core' ($doc.checks[0].id -eq 'proxy_core') "实际=$($doc.checks[0].id)"
    Assert '最后一项是 ecosystem' ($doc.checks[-1].id -eq 'ecosystem') "实际=$($doc.checks[-1].id)"
    Assert 'IP纯净度没有伪造检查项' (@($doc.checks | Where-Object { $_.id -eq 'ip_purity' }).Count -eq 0)
    Assert '更优节点没有伪造检查项' (@($doc.checks | Where-Object { $_.id -eq 'better_node' }).Count -eq 0)
    Assert 'unknown 为空' (@($doc.summary.unknown).Count -eq 0) "实际=$(@($doc.summary.unknown) -join ',')"
    Assert 'blockers 为空' (@($doc.summary.blockers).Count -eq 0) "实际=$(@($doc.summary.blockers) -join ',')"
    Assert 'report_id 是 32 位十六进制' ($doc.report_id -match '^[0-9a-f]{32}$') "实际=$($doc.report_id)"
    Assert 'config_fingerprint 是 64 位十六进制' ($doc.config_fingerprint -match '^[0-9a-f]{64}$') "实际=$($doc.config_fingerprint)"
    $coreHash = (Get-FileHash -LiteralPath $core -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert 'core_sha256 等于当前核心脚本' ($doc.core_sha256 -eq $coreHash) "实际=$($doc.core_sha256)"
    Assert 'environment 读取 checks 之外的环境层字段' ($doc.environment.proxy_mode -eq 'clash-verge' -and $doc.environment.country -eq 'US')
    $checkedAt = [DateTimeOffset]$doc.checks[0].checked_at
    Assert 'checked_at 绑定报告头时间' ($checkedAt.ToString('yyyy-MM-ddTHH:mm:ss') -eq '2026-11-14T12:00:00') "实际=$checkedAt"
    $created = [DateTimeOffset]::Parse($doc.created_at)
    $expires = [DateTimeOffset]::Parse($doc.expires_at)
    $ttl = ($expires - $created).TotalMinutes
    Assert '报告有效期为 30 分钟' ([math]::Abs($ttl - 30) -lt 0.1) "实际=$ttl"

    $second = Invoke-Report @('report', $fixture)
    Assert '相同输入指纹稳定' ($second.config_fingerprint -eq $doc.config_fingerprint)
    Assert '每次报告生成新的 report_id' ($second.report_id -ne $doc.report_id)

    Set-CheckConfig '{"disabled":["DNS"],"allowOptionalFailures":true,"logging":true}'
    $changed = Invoke-Report @('report', $fixture)
    Assert 'checks 配置变化会改变指纹' ($changed.config_fingerprint -ne $doc.config_fingerprint)

    Set-CheckConfig '{"disabled":["DNS"],"allowOptionalFailures":false,"logging":true}'
    $baseFixture = Join-Path $base 'last-check.txt'
    Write-Fixture $baseFixture (New-CheckLines)
    $defaultDoc = Invoke-Report @('report')
    Assert 'report 无参数时读 last-check.txt' (@($defaultDoc.checks).Count -eq 14) "实际=$(@($defaultDoc.checks).Count)"

    $duplicate = @(New-CheckLines)
    $duplicate = @($duplicate[0..3]) + @('代理内核=warn:重复行') + @($duplicate[4..($duplicate.Count - 1)])
    $duplicateFixture = Join-Path $root 'duplicate.txt'
    Write-Fixture $duplicateFixture $duplicate
    $duplicateDoc = Invoke-Report @('report', $duplicateFixture)
    Assert '重复项被记录' (@($duplicateDoc.summary.duplicates) -contains '代理内核') "实际=$(@($duplicateDoc.summary.duplicates) -join ',')"
    Assert '重复项使 verdict 为 violated' ($duplicateDoc.verdict -eq 'violated') "实际=$($duplicateDoc.verdict)"
    Assert '重复项只保留第一次的状态' ((@($duplicateDoc.checks | Where-Object { $_.id -eq 'proxy_core' })[0]).state -eq 'ok')

    $noCritical = @(New-CheckLines) | Where-Object { $_ -notmatch '^代理内核=' }
    $criticalFixture = Join-Path $root 'missing-critical.txt'
    Write-Fixture $criticalFixture ([string[]]$noCritical)
    $criticalDoc = Invoke-Report @('report', $criticalFixture)
    Assert '缺关键项写入 missing_critical' (@($criticalDoc.summary.missing_critical) -contains '代理内核') "实际=$(@($criticalDoc.summary.missing_critical) -join ',')"
    Assert '缺关键项使 verdict 为 incomplete' ($criticalDoc.verdict -eq 'incomplete') "实际=$($criticalDoc.verdict)"

    $allSkipFixture = Join-Path $root 'all-skip.txt'
    Write-Fixture $allSkipFixture (New-CheckLines 'skip')
    $allSkipDoc = Invoke-Report @('report', $allSkipFixture)
    Assert '全 skip 的 passed 为 0' ([int]$allSkipDoc.summary.passed -eq 0) "实际=$($allSkipDoc.summary.passed)"
    Assert '全 skip 的 skipped 为 14' ([int]$allSkipDoc.summary.skipped -eq 14) "实际=$($allSkipDoc.summary.skipped)"
    Assert '全 skip 使 verdict 为 incomplete' ($allSkipDoc.verdict -eq 'incomplete') "实际=$($allSkipDoc.verdict)"

    $unknownFixture = Join-Path $root 'unknown.txt'
    $unknownLines = @(New-CheckLines) + @('自定义项=warn:只有本地证据')
    Write-Fixture $unknownFixture $unknownLines
    $unknownDoc = Invoke-Report @('report', $unknownFixture)
    $unknownItem = @($unknownDoc.checks | Where-Object { $_.name -eq '自定义项' })[0]
    Assert '未知项保留名称' ($null -ne $unknownItem)
    Assert '未知项 ID 带 unknown- 前缀' ($unknownItem.id -match '^unknown-[0-9a-f]{12}$') "实际=$($unknownItem.id)"
    Assert '未知项 known=false' ($unknownItem.known -eq $false)
    Assert '未知项不冒充关键项' ($unknownItem.critical -eq $false)
    Assert '未知项进入 summary.unknown' (@($unknownDoc.summary.unknown) -contains '自定义项')
    Assert '未知项不改变 established 结论' ($unknownDoc.verdict -eq 'established') "实际=$($unknownDoc.verdict)"
} finally {
    foreach ($name in $envNames) {
        [Environment]::SetEnvironmentVariable($name, $savedEnv[$name], 'Process')
    }
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($script:failures -gt 0) {
    "FAILED: $script:failures 项"
    exit 1
}
'ALL PASS'
