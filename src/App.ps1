#requires -Version 5.1
[CmdletBinding()]
param([switch]$SmokeTest, [switch]$Demo, [string]$PreviewImage, [switch]$EmbeddedHost)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
if (-not $EmbeddedHost) { Import-Module (Join-Path $PSScriptRoot 'JdkSwitcher.Core.psm1') -Force }
elseif (-not (Get-Module -Name JdkSwitcher.Core)) { throw 'Embedded core module was not loaded.' }
if ($PreviewImage -and (-not $Demo -or -not $SmokeTest)) { throw 'PreviewImage requires -Demo -SmokeTest to avoid including local information.' }

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="JDK Switcher" Width="1180" Height="820" MinWidth="1000" MinHeight="720"
        WindowStartupLocation="CenterScreen" Background="#F3F5F9" FontFamily="Microsoft YaHei UI" FontSize="13">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Padding" Value="16,10"/><Setter Property="Margin" Value="0,0,10,0"/>
      <Setter Property="Background" Value="White"/><Setter Property="Foreground" Value="#24334D"/>
      <Setter Property="BorderBrush" Value="#D9DFEA"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="ButtonBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="7" Padding="{TemplateBinding Padding}">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.82"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.4"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="DataGridColumnHeader"><Setter Property="Background" Value="#F7F9FC"/><Setter Property="Foreground" Value="#6A7890"/><Setter Property="Padding" Value="14,12"/><Setter Property="BorderThickness" Value="0"/></Style>
    <Style TargetType="DataGridCell"><Setter Property="Padding" Value="14,12"/><Setter Property="BorderThickness" Value="0"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="DataGridCell"><Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}"><ContentPresenter VerticalAlignment="Center"/></Border></ControlTemplate></Setter.Value></Setter></Style>
    <Style TargetType="DataGridRow"><Setter Property="Background" Value="White"/><Setter Property="Foreground" Value="#24334D"/><Style.Triggers><Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#E6EEFF"/><Setter Property="Foreground" Value="#214BC4"/></Trigger></Style.Triggers></Style>
  </Window.Resources>
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="208"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <Border Background="#162239" Grid.Column="0">
      <Grid Margin="24,32,20,24">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <StackPanel>
          <Border Background="#3C6CF0" Width="46" Height="46" CornerRadius="12" HorizontalAlignment="Left"><TextBlock Text="J" FontSize="29" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
          <TextBlock Text="JDK Switcher" Foreground="White" FontSize="20" FontWeight="SemiBold" Margin="0,18,0,6"/>
          <TextBlock Text="让 Java 环境切换更安心" Foreground="#92A4C2" FontSize="11"/>
        </StackPanel>
        <Border Grid.Row="1" Background="#253955" CornerRadius="7" Padding="14,12" Margin="-4,36,0,0"><TextBlock Text="环境管理" Foreground="#DAE6FF" FontWeight="SemiBold"/></Border>
        <StackPanel Grid.Row="3">
          <TextBlock Text="本地运行 · 无遥测" Foreground="#C7D4E9" FontSize="12" Margin="0,0,0,8"/>
          <TextBlock Text="先备份，再修改。&#10;随时查看与恢复。" Foreground="#92A4C2" FontSize="11" LineHeight="20"/>
          <TextBlock Text="v1.1.0  /  MIT" Foreground="#7185A6" FontSize="11" Margin="0,24,0,0"/>
        </StackPanel>
      </Grid>
    </Border>
    <Grid Grid.Column="1" Margin="30,26,30,22">
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
      <Grid>
        <StackPanel><TextBlock Text="Java 环境" FontSize="27" FontWeight="SemiBold" Foreground="#172641"/><TextBlock Text="识别已安装的 JDK，安全切换开发环境。" Foreground="#748198" Margin="0,6,0,0"/></StackPanel>
        <Border HorizontalAlignment="Right" VerticalAlignment="Top" Background="#E3EBFB" Padding="12,7" CornerRadius="14"><TextBlock x:Name="PrivilegeLabel" Text="标准权限" Foreground="#355AB1" FontSize="11"/></Border>
      </Grid>
      <Border Grid.Row="1" Background="White" BorderBrush="#E2E7F0" BorderThickness="1" CornerRadius="10" Padding="18,14" Margin="0,20,0,16">
        <StackPanel><TextBlock Text="已保存的环境配置" Foreground="#748198" FontSize="11"/><TextBlock x:Name="CurrentHome" Text="正在读取…" Foreground="#20314E" FontWeight="SemiBold" Margin="0,6,0,0" TextWrapping="Wrap"/><TextBlock x:Name="CurrentJava" Foreground="#748198" FontSize="11" Margin="0,6,0,0" TextWrapping="Wrap"/></StackPanel>
      </Border>
      <Grid Grid.Row="2" Margin="0,0,0,10">
        <TextBlock x:Name="CountLabel" Text="已发现的 JDK" Foreground="#24334D" FontWeight="SemiBold" VerticalAlignment="Center"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right"><Button x:Name="ScanButton" Content="刷新扫描" Padding="13,7"/><Button x:Name="AddButton" Content="添加目录" Padding="13,7" Margin="0"/></StackPanel>
      </Grid>
      <Border Grid.Row="3" Background="White" BorderBrush="#E2E7F0" BorderThickness="1" CornerRadius="8" ClipToBounds="True" MinHeight="130">
        <DataGrid x:Name="JdkGrid" AutoGenerateColumns="False" IsReadOnly="True" SelectionMode="Single" SelectionUnit="FullRow" CanUserAddRows="False" CanUserDeleteRows="False" CanUserResizeRows="False" HeadersVisibility="Column" GridLinesVisibility="None" BorderThickness="0" RowHeaderWidth="0" Background="White" HorizontalScrollBarVisibility="Auto">
          <DataGrid.Columns>
            <DataGridTextColumn Header="版本" Binding="{Binding Version}" Width="115"/>
            <DataGridTextColumn Header="发行商" Binding="{Binding Vendor}" Width="170"/>
            <DataGridTextColumn Header="架构" Binding="{Binding Architecture}" Width="70"/>
            <DataGridTextColumn Header="安装目录" Binding="{Binding Home}" Width="*" MinWidth="210"/>
          </DataGrid.Columns>
        </DataGrid>
      </Border>
      <Grid Grid.Row="4" Margin="0,16,0,12">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center"><TextBlock Text="切换范围" Foreground="#52627B" VerticalAlignment="Center" Margin="0,0,12,0"/><ComboBox x:Name="ScopeBox" Width="182" Height="33" VerticalContentAlignment="Center" SelectedIndex="0"><ComboBoxItem Content="当前用户（无需提权）" Tag="User"/><ComboBoxItem Content="系统级（需要管理员）" Tag="Machine"/></ComboBox></StackPanel>
        <Button x:Name="ElevateButton" Content="以管理员重新打开" HorizontalAlignment="Right" Padding="13,7" Margin="0"/>
      </Grid>
      <Border Grid.Row="5" Background="#EAF0FA" BorderBrush="#D7E1F3" BorderThickness="1" CornerRadius="8" Padding="14,12">
        <StackPanel>
          <TextBlock x:Name="PreviewTitle" Text="变更预览" FontWeight="SemiBold" Foreground="#2D456F" Margin="0,0,0,8"/>
          <TextBox x:Name="PreviewText" Text="选择一个 JDK 后，这里会展示写入前后的完整配置。" IsReadOnly="True" Height="115" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Background="Transparent" BorderThickness="0" Foreground="#536887" FontSize="11" FontFamily="Consolas, Microsoft YaHei UI" TextWrapping="NoWrap"/>
        </StackPanel>
      </Border>
      <StackPanel Grid.Row="6" Margin="0,14,0,0">
        <Grid>
          <StackPanel Orientation="Horizontal"><Button x:Name="SwitchButton" Content="备份并一键切换" Background="#3565DE" Foreground="White" BorderBrush="#3565DE" IsEnabled="False"/><Button x:Name="RestoreButton" Content="恢复备份"/><Button x:Name="BackupButton" Content="备份目录" Margin="0"/></StackPanel>
        </Grid>
        <TextBlock x:Name="StatusText" Text="扫描只读取元数据，不会执行 JDK 程序。" Foreground="#748198" FontSize="11" Margin="0,12,0,0" TextWrapping="Wrap"/>
      </StackPanel>
    </Grid>
  </Grid>
</Window>
'@

$reader = New-Object Xml.XmlNodeReader($xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
$controls = @{}
foreach ($name in @('PrivilegeLabel', 'CurrentHome', 'CurrentJava', 'CountLabel', 'ScanButton', 'AddButton', 'JdkGrid', 'ScopeBox', 'ElevateButton', 'PreviewTitle', 'PreviewText', 'SwitchButton', 'RestoreButton', 'BackupButton', 'StatusText')) {
    $controls[$name] = $window.FindName($name)
}
$script:plan = $null
$script:manualRoots = @()
$script:updating = $false

function Set-Status {
    param([string]$Text, [bool]$IsError = $false)
    $controls.StatusText.Text = $Text
    $controls.StatusText.Foreground = if ($IsError) { [Windows.Media.Brushes]::Firebrick } else { [Windows.Media.BrushConverter]::new().ConvertFromString('#60738E') }
}

function Show-Plan {
    param($Plan)
    $script:plan = $Plan
    $lines = @()
    foreach ($change in $Plan.Changes) {
        $scopeName = if ($change.After.Scope -eq 'User') { '用户' } else { '系统' }
        $oldValue = if ($change.Before.Exists) { $change.Before.Value } else { '(未设置)' }
        $newValue = if ($change.After.Exists) { $change.After.Value } else { '(删除此值)' }
        $lines += "[$scopeName] $($change.After.Name)`r`n  原值 [$($change.Before.Kind)]：$oldValue`r`n  新值 [$($change.After.Kind)]：$newValue`r`n"
    }
    if ($lines.Count -eq 0) { $lines = @('配置已是目标状态，无需修改。') }
    $controls.PreviewText.Text = $lines -join "`r`n"
    $controls.PreviewTitle.Text = if ($Plan.Type -eq 'Restore') { '恢复预览 · 确认后将再次备份当前配置' } else { '切换预览 · 原有 Path 条目将保留' }
    $controls.SwitchButton.Content = if ($Plan.Type -eq 'Restore') { '备份并确认恢复' } else { '备份并一键切换' }
    $needsAdmin = @($Plan.Changes | Where-Object { $_.After.Scope -eq 'Machine' }).Count -gt 0
    $controls.SwitchButton.IsEnabled = @($Plan.Changes).Count -gt 0 -and (-not $needsAdmin -or (Test-JdkAdministrator))
    if ($needsAdmin -and -not (Test-JdkAdministrator)) {
        Set-Status '预览已就绪。系统级变更需要点击“以管理员重新打开”，然后重新选择 JDK。' $true
    } elseif (@($Plan.Changes).Count -gt 0) {
        Set-Status '请核对上方变更。确认后自动备份、写入并回读校验。已有终端与 IDE 需要重新打开。'
    } else { Set-Status '配置已是目标状态。' }
}

function Update-Plan {
    if ($script:updating) { return }
    $script:plan = $null
    $controls.SwitchButton.IsEnabled = $false
    $controls.SwitchButton.Content = '备份并一键切换'
    $selected = $controls.JdkGrid.SelectedItem
    if ($null -eq $selected) { return }
    if ($Demo) {
        $controls.PreviewTitle.Text = '切换预览 · 原有 Path 条目将保留'
        $controls.PreviewText.Text = "[系统] JAVA_HOME`r`n  原值 [String]：C:\Java\jdk-17`r`n  新值 [String]：C:\Java\jdk-21`r`n`r`n[系统] Path`r`n  原值 [ExpandString]：%JAVA_HOME%\bin;%SystemRoot%\System32`r`n  新值 [ExpandString]：C:\Java\jdk-21\bin;%JAVA_HOME%\bin;%SystemRoot%\System32"
        Set-Status '演示模式 · 所有数据均为虚构示例，写入操作已禁用。'
        return
    }
    try {
        $scope = [string]$controls.ScopeBox.SelectedItem.Tag
        Show-Plan (New-JdkSwitchPlan -Home $selected.Home -Scope $scope)
    } catch {
        $controls.PreviewTitle.Text = '无法安全切换'
        $controls.PreviewText.Text = $_.Exception.Message
        Set-Status $_.Exception.Message $true
    }
}

function Update-Scan {
    $script:updating = $true
    $script:plan = $null
    $controls.SwitchButton.IsEnabled = $false
    $controls.PreviewText.Text = '选择一个 JDK 后，这里会展示写入前后的完整配置。'
    $controls.PreviewTitle.Text = '变更预览'
    try {
        if ($Demo) {
            $controls.CurrentHome.Text = 'JAVA_HOME  C:\Java\jdk-17'
            $controls.CurrentJava.Text = '持久化 Path 中的首个 Java：C:\Java\jdk-17\bin\java.exe'
            $controls.JdkGrid.ItemsSource = @(
                [pscustomobject]@{ Version='21.0.6'; Vendor='Eclipse Adoptium'; Architecture='x64'; Home='C:\Java\jdk-21' },
                [pscustomobject]@{ Version='17.0.14'; Vendor='Microsoft'; Architecture='x64'; Home='C:\Java\jdk-17' },
                [pscustomobject]@{ Version='1.8.0_442'; Vendor='Amazon Corretto'; Architecture='x64'; Home='C:\Java\jdk-8' }
            )
            $controls.CountLabel.Text = '已发现的 JDK  /  3'
            Set-Status '演示模式 · 所有数据均为虚构示例，写入操作已禁用。'
            return
        }
        $snapshot = Get-JdkSnapshot
        $map = Get-JdkVariableMap $snapshot
        $controls.CurrentHome.Text = if ($map.ContainsKey('JAVA_HOME')) { 'JAVA_HOME  ' + $map['JAVA_HOME'] } else { 'JAVA_HOME 尚未设置' }
        $resolution = Get-JdkPathResolution $snapshot
        $controls.CurrentJava.Text = if ($resolution.Uncertain) { 'Path 检查：' + $resolution.Reason } elseif ($resolution.File) { '持久化 Path 中的首个 Java：' + $resolution.File } else { '持久化 Path 中未找到 Java' }
        $items = @(Find-JdkInstallations -Snapshot $snapshot -AdditionalRoots $script:manualRoots)
        $controls.JdkGrid.ItemsSource = $items
        $controls.CountLabel.Text = '已发现的 JDK  /  ' + $items.Count
        Set-Status '扫描完成。未找到的安装可通过“添加目录”指定；扫描不会执行 Java。'
    } catch { Set-Status $_.Exception.Message $true }
    finally { $script:updating = $false }
}

$controls.JdkGrid.Add_SelectionChanged({ Update-Plan })
$controls.ScopeBox.Add_SelectionChanged({ Update-Plan })
$controls.ScanButton.Add_Click({ Update-Scan })
$controls.AddButton.Add_Click({
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    $dialog.Description = '选择 JDK 根目录（其中应包含 bin 和 release）'
    $dialog.ShowNewFolderButton = $false
    try {
        if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
            $jdk = Get-JdkInstallation $dialog.SelectedPath
            $script:manualRoots += $jdk.Home
            Update-Scan
            foreach ($item in $controls.JdkGrid.Items) {
                if ($item.Home -ieq $jdk.Home) { $controls.JdkGrid.SelectedItem = $item; break }
            }
        }
    } catch { Set-Status $_.Exception.Message $true }
    finally { $dialog.Dispose() }
})
$controls.SwitchButton.Add_Click({
    if ($null -eq $script:plan) { return }
    $controls.SwitchButton.IsEnabled = $false
    try {
        $result = Invoke-JdkTransaction $script:plan
        $script:plan = $null
        Update-Scan
        if ($result.Changed) {
            $text = '完成，原配置已备份。请重新打开终端与 IDE；若仍使用旧环境，请注销后登录。'
            if ($result.Warning) { $text += ' ' + $result.Warning }
            Set-Status $text
            $controls.PreviewText.Text = '备份文件：' + $result.Backup + "`r`n`r`n此工具只修改持久化环境，不会关闭进程或改变已打开终端的环境。"
        } else { Set-Status '配置未变化。' }
    } catch {
        $script:plan = $null
        Set-Status $_.Exception.Message $true
        $controls.PreviewTitle.Text = '操作未完成'
        $controls.PreviewText.Text = $_.Exception.Message
    }
})
$controls.RestoreButton.Add_Click({
    try {
        $backups = @(Get-JdkBackups)
        if ($backups.Count -eq 0) { Set-Status '暂无备份。首次切换前会自动创建。'; return }
        $dialog = New-Object Microsoft.Win32.OpenFileDialog
        $dialog.Title = '选择本机当前账户的环境备份'
        $dialog.InitialDirectory = $backups[0].DirectoryName
        $dialog.Filter = 'JDK Switcher 备份 (*.json)|*.json'
        if ($dialog.ShowDialog($window)) { Show-Plan (New-JdkRestorePlan -File $dialog.FileName) }
    } catch { Set-Status $_.Exception.Message $true }
})
$controls.BackupButton.Add_Click({
    $directory = Join-Path (Get-JdkDataDirectory) 'backups'
    if (Test-Path -LiteralPath $directory) { Start-Process explorer.exe -ArgumentList ('"' + $directory + '"') }
    else { Set-Status '首次切换后将创建备份目录。' }
})
$controls.ElevateButton.Add_Click({
    try {
        if ($EmbeddedHost) {
            Start-Process -FilePath $JdkSwitcherExecutable -Verb RunAs -WindowStyle Hidden
        } else {
            $exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            $appPath = Join-Path $PSScriptRoot 'App.ps1'
            Start-Process -FilePath $exe -Verb RunAs -WindowStyle Hidden -ArgumentList ('-NoLogo -NoProfile -STA -WindowStyle Hidden -File "' + $appPath + '"')
        }
        $window.Close()
    } catch { Set-Status '管理员启动未完成，当前窗口仍可使用。' $true }
})

$admin = Test-JdkAdministrator
$controls.PrivilegeLabel.Text = if ($admin) { '管理员权限' } else { '标准权限' }
$controls.ElevateButton.Visibility = if ($admin) { 'Collapsed' } else { 'Visible' }
if ($Demo) {
    $controls.PrivilegeLabel.Text = '演示模式'
    $controls.ScopeBox.SelectedIndex = 1
    foreach ($name in @('AddButton', 'RestoreButton', 'BackupButton', 'ElevateButton')) { $controls[$name].IsEnabled = $false }
}

if ($SmokeTest) {
    # Loads the real XAML, runs the read-only scan and creates a preview only.
    Update-Scan
    if ($controls.JdkGrid.Items.Count -gt 0) {
        $controls.ScopeBox.SelectedIndex = 1
        $controls.JdkGrid.SelectedIndex = 0
        if (-not $Demo -and $null -eq $script:plan) { throw ('Preview smoke test failed: ' + $controls.PreviewText.Text) }
    }
    if ($controls.StatusText.Foreground -eq [Windows.Media.Brushes]::Firebrick -and $controls.JdkGrid.Items.Count -eq 0) { throw $controls.StatusText.Text }
    if ($PreviewImage) {
        $window.Show()
        $window.UpdateLayout()
        $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$window.ActualWidth, [int]$window.ActualHeight, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($window)
        $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $stream = [IO.File]::Create([IO.Path]::GetFullPath($PreviewImage))
        try { $encoder.Save($stream) } finally { $stream.Dispose() }
    }
    Write-Output ('UI smoke test passed; discovered installations: ' + $controls.JdkGrid.Items.Count)
    $window.Close()
    return
}
$window.Add_ContentRendered({ Update-Scan })
try { [void]$window.ShowDialog() }
catch { if ($EmbeddedHost) { throw }; [void][Windows.MessageBox]::Show($_.Exception.Message, 'JDK Switcher', 'OK', 'Error'); throw }
