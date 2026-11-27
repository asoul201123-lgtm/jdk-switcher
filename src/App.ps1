#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$SmokeTest,
    [switch]$Demo,
    [string]$PreviewImage,
    [ValidateSet('Local', 'Download')][string]$PreviewPage = 'Local',
    [switch]$EmbeddedHost
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
if (-not $EmbeddedHost) {
    Import-Module (Join-Path $PSScriptRoot 'JdkSwitcher.Core.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'JdkSwitcher.Download.psm1') -Force
    $script:coreModuleText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'JdkSwitcher.Core.psm1'))
    $script:downloadModuleText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'JdkSwitcher.Download.psm1'))
} else {
    if (-not (Get-Module -Name JdkSwitcher.Core)) { throw 'Embedded core module was not loaded.' }
    if (-not (Get-Module -Name JdkSwitcher.Download)) { throw 'Embedded download module was not loaded.' }
    $script:coreModuleText = $JdkSwitcherCoreModuleText
    $script:downloadModuleText = $JdkSwitcherDownloadModuleText
}
if ($PreviewImage -and (-not $Demo -or -not $SmokeTest)) { throw 'PreviewImage requires -Demo -SmokeTest to avoid including local information.' }

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="JDK Switcher" Width="1080" Height="660" MinWidth="640" MinHeight="570"
        WindowStartupLocation="CenterScreen" Background="#F4F6F8" Foreground="#182230"
        FontFamily="Segoe UI, Microsoft YaHei UI" FontSize="13" UseLayoutRounding="True">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Padding" Value="12,7"/>
      <Setter Property="MinHeight" Value="34"/>
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="#273444"/>
      <Setter Property="BorderBrush" Value="#CDD5DE"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Chrome" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="5" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Chrome" Property="Opacity" Value="0.82"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Chrome" Property="Opacity" Value="0.70"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Chrome" Property="BorderBrush" Value="#17202D"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Chrome" Property="Opacity" Value="0.50"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#005BAA"/>
      <Setter Property="BorderBrush" Value="#005BAA"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="18,8"/>
    </Style>
    <Style x:Key="Pane" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="#DCE2E9"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="8"/>
    </Style>
    <Style x:Key="PaneHeading" TargetType="TextBlock">
      <Setter Property="FontSize" Value="18"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="MutedLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#536174"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Padding" Value="14,9"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="TabChrome" BorderThickness="0,0,0,2" BorderBrush="Transparent" Background="Transparent"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter x:Name="TabLabel" ContentSource="Header" RecognizesAccessKey="True" TextElement.Foreground="#536174"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="TabChrome" Property="Background" Value="#EAF0F6"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="TabChrome" Property="BorderBrush" Value="#005BAA"/>
                <Setter TargetName="TabLabel" Property="TextElement.FontWeight" Value="SemiBold"/>
                <Setter TargetName="TabLabel" Property="TextElement.Foreground" Value="#005BAA"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="TabChrome" Property="Background" Value="#E4EEF8"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ScopeSelector" TargetType="ComboBox">
      <Setter Property="Width" Value="142"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton x:Name="ScopeToggle" Focusable="False" ClickMode="Press" Background="White" BorderBrush="#CDD5DE"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="5">
                      <TextBlock Text="⌄" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,10,3"/>
                    </Border>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                Margin="10,0,25,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
              <Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" Focusable="False" AllowsTransparency="True">
                <Border Background="White" BorderBrush="#CDD5DE" BorderThickness="1" CornerRadius="5" Padding="3"
                        MinWidth="{TemplateBinding ActualWidth}" MaxHeight="{TemplateBinding MaxDropDownHeight}">
                  <ScrollViewer><ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ScopeToggle" Property="Background" Value="#F4F7FA"/></Trigger>
              <Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter TargetName="ScopeToggle" Property="BorderBrush" Value="#005BAA"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.55"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="#F4F6F8"/>
      <Setter Property="Foreground" Value="#536174"/>
      <Setter Property="Padding" Value="12,8"/>
      <Setter Property="BorderThickness" Value="0"/>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="DataGridCell">
            <Border Background="Transparent" Padding="12,0"><ContentPresenter VerticalAlignment="Center"/></Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True"><Setter Property="Foreground" Value="#06497E"/></Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="DataGridRow">
      <Setter Property="Background" Value="White"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#F4F7FA"/></Trigger>
        <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#E4EFFA"/></Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="ListBoxItem">
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="Row" Background="Transparent" BorderBrush="Transparent" BorderThickness="2,0,0,0" Padding="12,9">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Row" Property="Background" Value="#F4F7FA"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Row" Property="Background" Value="#E4EFFA"/>
                <Setter TargetName="Row" Property="BorderBrush" Value="#005BAA"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Row" Property="BorderBrush" Value="#005BAA"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border Background="#F4F6F8">
  <Grid x:Name="LayoutRoot" Margin="24,20,24,14">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <DockPanel LastChildFill="True" Margin="0,0,0,15">
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
        <TextBlock x:Name="PrivilegeLabel" Text="标准权限" Foreground="#536174" VerticalAlignment="Center" Margin="0,0,12,0"/>
        <Button x:Name="RestoreButton" Content="恢复备份" Margin="0,0,8,0"/>
        <Button x:Name="BackupButton" Content="备份目录"/>
      </StackPanel>
      <TextBlock Text="JDK Switcher" FontSize="27" FontWeight="SemiBold" VerticalAlignment="Center"/>
    </DockPanel>
    <Border Grid.Row="1" Style="{StaticResource Pane}" Padding="14,10" Margin="0,0,0,9">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="136"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <TextBlock Text="已保存的 Java 配置" FontWeight="SemiBold" VerticalAlignment="Top" Margin="0,2,10,0"/>
        <StackPanel Grid.Column="1">
          <TextBlock x:Name="CurrentHome" Text="正在读取…" TextTrimming="CharacterEllipsis" ToolTip="{Binding Text, RelativeSource={RelativeSource Self}}"/>
          <TextBlock x:Name="CurrentJava" Foreground="#536174" Margin="0,3,0,0" TextTrimming="CharacterEllipsis" ToolTip="{Binding Text, RelativeSource={RelativeSource Self}}"/>
        </StackPanel>
      </Grid>
    </Border>
    <TabControl x:Name="MainTabs" Grid.Row="2" Background="Transparent" BorderThickness="0" Padding="0">
      <TabControl.Template>
        <ControlTemplate TargetType="TabControl">
          <Grid>
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <Border BorderThickness="0,0,0,1" BorderBrush="#DCE2E9">
              <TabPanel IsItemsHost="True" KeyboardNavigation.TabIndex="0"/>
            </Border>
            <ContentPresenter x:Name="PART_SelectedContentHost" Grid.Row="1" ContentSource="SelectedContent" Margin="0,12,0,0"/>
          </Grid>
        </ControlTemplate>
      </TabControl.Template>
      <TabItem x:Name="LocalTab" Header="本机 JDK" IsSelected="True">
        <Grid x:Name="LocalLayout">
          <Grid.ColumnDefinitions><ColumnDefinition Width="5*"/><ColumnDefinition Width="16"/><ColumnDefinition Width="6*"/></Grid.ColumnDefinitions>
          <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="0"/><RowDefinition Height="0"/></Grid.RowDefinitions>
          <Border Style="{StaticResource Pane}">
            <Grid>
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
              <DockPanel Margin="14,12">
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                  <Button x:Name="ScanButton" Content="刷新" Margin="0,0,8,0"/>
                  <Button x:Name="AddButton" Content="添加目录"/>
                </StackPanel>
                <TextBlock x:Name="CountLabel" Text="已安装" Style="{StaticResource PaneHeading}" VerticalAlignment="Center"/>
              </DockPanel>
              <DataGrid x:Name="JdkGrid" Grid.Row="1" AutomationProperties.Name="已安装的 JDK" AutoGenerateColumns="False"
                        IsReadOnly="True" SelectionMode="Single" SelectionUnit="FullRow" CanUserAddRows="False"
                        CanUserDeleteRows="False" CanUserResizeRows="False" HeadersVisibility="Column" GridLinesVisibility="None"
                        BorderThickness="0" Background="Transparent" RowHeight="40" HorizontalScrollBarVisibility="Auto" Margin="1,0,1,5">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="版本" Binding="{Binding Version}" Width="112" FontWeight="SemiBold"/>
                  <DataGridTextColumn Header="发行商" Binding="{Binding Vendor}" Width="*" MinWidth="124">
                    <DataGridTextColumn.ElementStyle>
                      <Style TargetType="TextBlock">
                        <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
                        <Setter Property="ToolTip" Value="{Binding Vendor}"/>
                      </Style>
                    </DataGridTextColumn.ElementStyle>
                  </DataGridTextColumn>
                  <DataGridTextColumn Header="架构" Binding="{Binding Architecture}" Width="66"/>
                </DataGrid.Columns>
              </DataGrid>
              <TextBlock x:Name="LocalEmpty" Grid.Row="1" Text="未找到 JDK。可添加安装目录，或在「下载 JDK」中获取新版本。"
                         Style="{StaticResource MutedLabel}" Margin="14,46,14,0" VerticalAlignment="Top" IsHitTestVisible="False" Visibility="Collapsed"/>
            </Grid>
          </Border>
          <Border x:Name="LocalDetails" Grid.Column="2" Style="{StaticResource Pane}">
            <Grid>
              <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                <StackPanel Margin="16,14,16,12">
                  <TextBlock x:Name="TargetTitle" Text="选择一个 JDK" Style="{StaticResource PaneHeading}"/>
                  <TextBox x:Name="TargetHome" AutomationProperties.Name="安装目录" IsReadOnly="True" Visibility="Collapsed"
                           Margin="0,5,0,0" BorderThickness="0" Padding="0" Foreground="#536174" Background="Transparent"
                           FontFamily="Consolas, Microsoft YaHei UI" TextWrapping="Wrap"/>
                  <WrapPanel Margin="0,14,0,0">
                    <TextBlock Text="切换范围" VerticalAlignment="Center" Margin="0,0,10,0"/>
                    <ComboBox x:Name="ScopeBox" AutomationProperties.Name="本机 JDK 切换范围" Style="{StaticResource ScopeSelector}" SelectedIndex="0">
                      <ComboBoxItem Content="当前用户" Tag="User"/><ComboBoxItem Content="系统级" Tag="Machine"/>
                    </ComboBox>
                    <Button x:Name="ElevateButton" Content="以管理员重新打开" Visibility="Collapsed"/>
                  </WrapPanel>
                  <Border Background="#F3F6FA" CornerRadius="5" Margin="0,14,0,0" Padding="12,10">
                    <StackPanel>
                      <TextBlock x:Name="PreviewTitle" Text="变更预览" FontWeight="SemiBold" TextWrapping="Wrap"/>
                      <TextBlock x:Name="PreviewSummary" Style="{StaticResource MutedLabel}" Margin="0,6,0,0"
                                 Text="选中本机 JDK 后，可查看 JAVA_HOME 和 Path 的变更。"/>
                      <Expander x:Name="PreviewDetails" Header="查看完整变更" Margin="0,8,0,0" Visibility="Collapsed">
                        <TextBox x:Name="PreviewText" AutomationProperties.Name="完整变更" IsReadOnly="True" Margin="0,7,0,0"
                                 BorderThickness="0" Padding="0" Background="Transparent" Foreground="#273444"
                                 FontFamily="Consolas, Microsoft YaHei UI" FontSize="12" TextWrapping="Wrap"/>
                      </Expander>
                    </StackPanel>
                  </Border>
                </StackPanel>
              </ScrollViewer>
              <Border Grid.Row="1" BorderThickness="0,1,0,0" BorderBrush="#E5EAF0" Padding="14,10">
                <Button x:Name="SwitchButton" Content="备份并切换" Style="{StaticResource PrimaryButton}" HorizontalAlignment="Right" IsEnabled="False"/>
              </Border>
            </Grid>
          </Border>
        </Grid>
      </TabItem>
      <TabItem x:Name="DownloadTab" Header="下载 JDK">
        <Grid x:Name="DownloadLayout">
          <Grid.ColumnDefinitions><ColumnDefinition Width="5*"/><ColumnDefinition Width="16"/><ColumnDefinition Width="6*"/></Grid.ColumnDefinitions>
          <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="0"/><RowDefinition Height="0"/></Grid.RowDefinitions>
          <Border Style="{StaticResource Pane}">
            <Grid>
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
              <DockPanel Margin="14,12">
                <Button x:Name="CatalogButton" Content="刷新目录" DockPanel.Dock="Right"/>
                <TextBlock Text="Eclipse Temurin" Style="{StaticResource PaneHeading}" VerticalAlignment="Center"/>
              </DockPanel>
              <ListBox x:Name="VersionList" Grid.Row="1" AutomationProperties.Name="可下载的 JDK 版本" Background="Transparent"
                       BorderThickness="0" Margin="1,0,1,5" ScrollViewer.HorizontalScrollBarVisibility="Disabled">
                <ListBox.ItemTemplate>
                  <DataTemplate>
                    <DockPanel LastChildFill="True">
                      <Border DockPanel.Dock="Right" CornerRadius="4" Background="#E2EEE8" Padding="7,2" Margin="8,0,0,0">
                        <Border.Style>
                          <Style TargetType="Border">
                            <Setter Property="Visibility" Value="Collapsed"/>
                            <Style.Triggers><DataTrigger Binding="{Binding IsLts}" Value="True"><Setter Property="Visibility" Value="Visible"/></DataTrigger></Style.Triggers>
                          </Style>
                        </Border.Style>
                        <TextBlock Text="LTS" Foreground="#1F6143" FontSize="11" FontWeight="SemiBold"/>
                      </Border>
                      <TextBlock Text="{Binding Major, StringFormat=JDK {0}}" FontWeight="SemiBold" VerticalAlignment="Center"/>
                    </DockPanel>
                  </DataTemplate>
                </ListBox.ItemTemplate>
              </ListBox>
            </Grid>
          </Border>
          <Border x:Name="DownloadDetails" Grid.Column="2" Style="{StaticResource Pane}">
            <Grid>
              <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                <StackPanel Margin="16,14,16,12">
                  <TextBlock x:Name="DownloadTitle" Text="选择下载版本" Style="{StaticResource PaneHeading}"/>
                  <TextBlock x:Name="DownloadPackageText" Text="Eclipse Adoptium 官方目录 · Windows ZIP" Style="{StaticResource MutedLabel}" Margin="0,5,0,0"/>
                  <WrapPanel Margin="0,14,0,0">
                    <TextBlock Text="切换范围" VerticalAlignment="Center" Margin="0,0,10,0"/>
                    <ComboBox x:Name="DownloadScopeBox" AutomationProperties.Name="下载后切换范围" Style="{StaticResource ScopeSelector}" SelectedIndex="0">
                      <ComboBoxItem Content="当前用户" Tag="User"/><ComboBoxItem Content="系统级" Tag="Machine"/>
                    </ComboBox>
                    <Button x:Name="DownloadElevateButton" Content="以管理员重新打开" Visibility="Collapsed"/>
                  </WrapPanel>
                  <Border Background="#F3F6FA" CornerRadius="5" Margin="0,14,0,0" Padding="12,10">
                    <StackPanel>
                      <TextBlock Text="下载与切换" FontWeight="SemiBold"/>
                      <TextBlock x:Name="DownloadRequirement" Text="系统级切换需要管理员权限。" TextWrapping="Wrap"
                                 Foreground="#895000" Margin="0,6,0,0" Visibility="Collapsed"/>
                      <ProgressBar x:Name="DownloadProgressBar" AutomationProperties.Name="下载进度" Height="6"
                                   Margin="0,9,0,2" Visibility="Collapsed" Background="#DFE7EF" Foreground="#005BAA" BorderThickness="0"/>
                      <TextBlock x:Name="DownloadDetailText" Text="正在等待版本目录。" Style="{StaticResource MutedLabel}" Margin="0,6,0,0"/>
                    </StackPanel>
                  </Border>
                </StackPanel>
              </ScrollViewer>
              <Border Grid.Row="1" BorderThickness="0,1,0,0" BorderBrush="#E5EAF0" Padding="14,10">
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                  <Button x:Name="CancelDownloadButton" Content="取消下载" Visibility="Collapsed" Margin="0,0,8,0"/>
                  <Button x:Name="DownloadNowButton" Content="下载并切换" Style="{StaticResource PrimaryButton}" IsEnabled="False"/>
                </StackPanel>
              </Border>
            </Grid>
          </Border>
        </Grid>
      </TabItem>
    </TabControl>
    <TextBlock x:Name="StatusText" Grid.Row="3" Text="正在扫描本机 JDK…" Margin="1,10,1,0" Foreground="#536174" FontSize="12"
               TextTrimming="CharacterEllipsis" ToolTip="{Binding Text, RelativeSource={RelativeSource Self}}"/>
  </Grid>
  </Border>
</Window>
'@

$reader = New-Object Xml.XmlNodeReader($xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
$controls = @{}
foreach ($name in @(
    'LayoutRoot', 'MainTabs', 'LocalTab', 'DownloadTab', 'LocalLayout', 'LocalDetails', 'DownloadLayout', 'DownloadDetails',
    'PrivilegeLabel', 'CurrentHome', 'CurrentJava', 'RestoreButton', 'BackupButton', 'StatusText',
    'CountLabel', 'ScanButton', 'AddButton', 'JdkGrid', 'LocalEmpty', 'TargetTitle', 'TargetHome', 'ScopeBox', 'ElevateButton',
    'PreviewTitle', 'PreviewSummary', 'PreviewDetails', 'PreviewText', 'SwitchButton',
    'CatalogButton', 'VersionList', 'DownloadTitle', 'DownloadPackageText', 'DownloadScopeBox', 'DownloadElevateButton',
    'DownloadRequirement', 'DownloadProgressBar', 'DownloadDetailText', 'CancelDownloadButton', 'DownloadNowButton'
)) {
    $controls[$name] = $window.FindName($name)
    if ($null -eq $controls[$name]) { throw "Main window is missing $name." }
}
$script:plan = $null
$script:manualRoots = @()
$script:updating = $false
$script:admin = Test-JdkAdministrator
$script:compactLayout = $false
$script:downloadJob = $null
$script:catalogRequested = $false
$script:downloadArchitecture = ''
$script:downloadClosePending = $false
$script:downloadTimer = New-Object Windows.Threading.DispatcherTimer
$script:downloadTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:downloadTimer.Add_Tick({ Update-DownloadJob })

function Update-Layout {
    $compact = $controls.LayoutRoot.ActualWidth -lt 760
    if ($compact -eq $script:compactLayout) { return }
    $script:compactLayout = $compact
    $star = [Windows.GridUnitType]::Star
    foreach ($page in @('Local', 'Download')) {
        $grid = $controls[$page + 'Layout']
        $details = $controls[$page + 'Details']
        if ($compact) {
            $grid.ColumnDefinitions[0].Width = [Windows.GridLength]::new(1, $star)
            $grid.ColumnDefinitions[1].Width = [Windows.GridLength]::new(0)
            $grid.ColumnDefinitions[2].Width = [Windows.GridLength]::new(0)
            $grid.RowDefinitions[0].Height = [Windows.GridLength]::new(2, $star)
            $grid.RowDefinitions[1].Height = [Windows.GridLength]::new(10)
            $grid.RowDefinitions[2].Height = [Windows.GridLength]::new(3, $star)
            [Windows.Controls.Grid]::SetColumn($details, 0)
            [Windows.Controls.Grid]::SetRow($details, 2)
        } else {
            $grid.ColumnDefinitions[0].Width = [Windows.GridLength]::new(5, $star)
            $grid.ColumnDefinitions[1].Width = [Windows.GridLength]::new(16)
            $grid.ColumnDefinitions[2].Width = [Windows.GridLength]::new(6, $star)
            $grid.RowDefinitions[0].Height = [Windows.GridLength]::new(1, $star)
            $grid.RowDefinitions[1].Height = [Windows.GridLength]::new(0)
            $grid.RowDefinitions[2].Height = [Windows.GridLength]::new(0)
            [Windows.Controls.Grid]::SetColumn($details, 2)
            [Windows.Controls.Grid]::SetRow($details, 0)
        }
    }
}

function Set-Status {
    param([string]$Text, [bool]$IsError = $false)
    $controls.StatusText.Text = $Text
    $controls.StatusText.Foreground = if ($IsError) { [Windows.Media.Brushes]::Firebrick } else { [Windows.Media.BrushConverter]::new().ConvertFromString('#536174') }
}

function Set-DownloadDetail {
    param([string]$Text, [bool]$IsError = $false)
    $controls.DownloadDetailText.Text = $Text
    $controls.DownloadDetailText.Foreground = if ($IsError) { [Windows.Media.Brushes]::Firebrick } else { [Windows.Media.BrushConverter]::new().ConvertFromString('#536174') }
}

function Update-LocalActions {
    $hasPlan = $null -ne $script:plan -and $script:plan.Changes.Count -gt 0
    $systemPlan = $hasPlan -and @($script:plan.Changes | Where-Object { $_.After.Scope -eq 'Machine' }).Count -gt 0
    $systemSelected = [string]$controls.ScopeBox.SelectedItem.Tag -eq 'Machine'
    $idle = $null -eq $script:downloadJob
    $controls.ElevateButton.Visibility = if (-not $script:admin -and ($systemPlan -or $systemSelected)) { 'Visible' } else { 'Collapsed' }
    $controls.ElevateButton.IsEnabled = $idle -and -not $Demo
    $controls.RestoreButton.IsEnabled = $idle -and -not $Demo
    $controls.SwitchButton.IsEnabled = $idle -and -not $Demo -and $hasPlan -and (-not $systemPlan -or $script:admin)
}

function Update-DownloadActions {
    $job = $script:downloadJob
    $idle = $null -eq $job
    $needsAdmin = [string]$controls.DownloadScopeBox.SelectedItem.Tag -eq 'Machine' -and -not $script:admin
    $controls.CatalogButton.IsEnabled = $idle -and -not $Demo
    $controls.VersionList.IsEnabled = $idle
    $controls.DownloadScopeBox.IsEnabled = $idle
    $controls.DownloadNowButton.IsEnabled = $idle -and -not $Demo -and -not $needsAdmin -and $null -ne $controls.VersionList.SelectedItem
    $controls.DownloadElevateButton.Visibility = if ($needsAdmin) { 'Visible' } else { 'Collapsed' }
    $controls.DownloadElevateButton.IsEnabled = $idle -and -not $Demo
    $controls.DownloadRequirement.Visibility = $controls.DownloadElevateButton.Visibility
    $controls.CancelDownloadButton.Visibility = if ($idle) { 'Collapsed' } else { 'Visible' }
    $controls.CancelDownloadButton.IsEnabled = -not $idle -and -not $job.CancelRequested
    Update-LocalActions
}

function Update-DownloadSelection {
    $selected = $controls.VersionList.SelectedItem
    $controls.DownloadTitle.Text = if ($null -eq $selected) { '选择下载版本' } else { '下载 JDK ' + $selected.Major }
    $architecture = if ($script:downloadArchitecture -eq 'aarch64') { ' · ARM64' } elseif ($script:downloadArchitecture) { ' · ' + $script:downloadArchitecture }
    $controls.DownloadPackageText.Text = 'Eclipse Adoptium 官方目录 · Windows ZIP' + $architecture + ' · SHA-256 校验'
    Update-DownloadActions
}

function Set-DownloadCatalog {
    param([object[]]$Catalog)
    $previous = $controls.VersionList.SelectedItem
    $controls.VersionList.ItemsSource = $Catalog
    if ($Catalog.Count -gt 0) {
        $preferred = if ($null -ne $previous) { $Catalog | Where-Object Major -eq $previous.Major | Select-Object -First 1 }
        if ($null -eq $preferred) { $preferred = $Catalog | Where-Object IsLts | Select-Object -First 1 }
        $controls.VersionList.SelectedItem = if ($null -ne $preferred) { $preferred } else { $Catalog[0] }
    }
    Update-DownloadSelection
}

function Start-DownloadWorker {
    param([ValidateSet('Catalog', 'Install')][string]$Action, [int]$Major = 0, [string]$Scope = 'User')
    if ($Demo -or $SmokeTest -or $null -ne $script:downloadJob) { return }
    if ($Action -eq 'Catalog') { $script:catalogRequested = $true }
    $powerShell = $null
    $runspace = $null
    $cancellation = $null
    try {
        $script:downloadArchitecture = Get-JdkDownloadArchitecture
        $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $cancellation = New-Object Threading.CancellationTokenSource
        $powerShell = [PowerShell]::Create()
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.ApartmentState = 'MTA'
        $runspace.ThreadOptions = 'ReuseThread'
        $runspace.Open()
        $powerShell.Runspace = $runspace
        $worker = {
            param($coreText, $downloadText, $action, $major, $architecture, $queue, $token)
            $ErrorActionPreference = 'Stop'
            New-Module -Name JdkSwitcher.Core -ScriptBlock ([scriptblock]::Create($coreText)) | Import-Module -Force
            New-Module -Name JdkSwitcher.Download -ScriptBlock ([scriptblock]::Create($downloadText)) | Import-Module -Force
            $token.ThrowIfCancellationRequested()
            if ($action -eq 'Catalog') {
                $catalog = @(Get-JdkDownloadCatalog)
                $token.ThrowIfCancellationRequested()
                return [pscustomobject]@{ Kind = 'Catalog'; Catalog = $catalog }
            }
            $package = Get-JdkDownloadPackage -Major $major -Architecture $architecture
            $token.ThrowIfCancellationRequested()
            $progress = { param($state) $queue.Enqueue($state) }.GetNewClosure()
            $jdk = Install-JdkDownload -Package $package -CancellationToken $token -Progress $progress
            [pscustomobject]@{ Kind = 'Installed'; Jdk = $jdk }
        }
        [void]$powerShell.AddScript($worker).AddArgument($script:coreModuleText).AddArgument($script:downloadModuleText).AddArgument($Action).AddArgument($Major).AddArgument($script:downloadArchitecture).AddArgument($queue).AddArgument($cancellation.Token)
        $handle = $powerShell.BeginInvoke()
    } catch {
        if ($null -ne $powerShell) { $powerShell.Dispose() }
        if ($null -ne $runspace) { $runspace.Dispose() }
        if ($null -ne $cancellation) { $cancellation.Dispose() }
        $controls.DownloadProgressBar.Visibility = 'Collapsed'
        Set-DownloadDetail $_.Exception.Message $true
        return
    }
    $script:downloadJob = [pscustomobject]@{
        PowerShell = $powerShell; Runspace = $runspace; Handle = $handle; Cancellation = $cancellation
        Queue = $queue; Action = $Action; Scope = $Scope; CancelRequested = $false
    }
    $controls.CancelDownloadButton.Content = if ($Action -eq 'Catalog') { '取消读取' } else { '取消下载' }
    $controls.DownloadProgressBar.Visibility = 'Visible'
    $controls.DownloadProgressBar.IsIndeterminate = $true
    $controls.DownloadProgressBar.Value = 0
    Set-DownloadDetail $(if ($Action -eq 'Catalog') { '正在读取官方版本目录…' } else { '正在准备下载…' })
    Update-DownloadSelection
    $script:downloadTimer.Start()
}

function Stop-DownloadWorker {
    if ($null -eq $script:downloadJob -or $script:downloadJob.CancelRequested) { return }
    $script:downloadJob.CancelRequested = $true
    $controls.CancelDownloadButton.IsEnabled = $false
    Set-DownloadDetail '正在取消，请等待当前步骤结束…'
    $script:downloadJob.Cancellation.Cancel()
}

function Select-InstalledJdk {
    param([string]$JdkHome)
    foreach ($item in $controls.JdkGrid.Items) {
        if ($item.Home -ieq $JdkHome) { $controls.JdkGrid.SelectedItem = $item; return }
    }
}

function Complete-DownloadAndSwitch {
    param($Jdk, [string]$Scope)
    $switchError = $null
    Set-DownloadDetail "JDK $($Jdk.Version) 已就绪，正在备份并切换…"
    try {
        $plan = New-JdkSwitchPlan -Home $Jdk.Home -Scope $Scope
        $result = Invoke-JdkTransaction $plan
    } catch { $switchError = $_.Exception.Message }

    Update-Scan
    Select-InstalledJdk $Jdk.Home
    if ($switchError) {
        Set-Status "JDK $($Jdk.Version) 已安装，自动切换未完成。" $true
        Set-DownloadDetail ("JDK $($Jdk.Version) 已保留在「本机 JDK」，可手动切换。" + [Environment]::NewLine + $switchError) $true
    } elseif ($result.Changed) {
        $message = "已切换至 JDK $($Jdk.Version)。原配置已备份，请重新打开终端与 IDE。"
        if ($result.Warning) { $message += ' ' + $result.Warning }
        Set-Status $message
        Set-DownloadDetail ($message + [Environment]::NewLine + '备份文件：' + $result.Backup)
    } else {
        $message = "JDK $($Jdk.Version) 已就绪，当前配置无需修改。"
        Set-Status $message
        Set-DownloadDetail $message
    }
}

function Update-DownloadJob {
    $job = $script:downloadJob
    if ($null -eq $job) { return }
    $state = $null
    while ($job.Queue.TryDequeue([ref]$state)) {
        if ($null -eq $state -or $job.CancelRequested) { continue }
        $controls.DownloadProgressBar.IsIndeterminate = ($state.Stage -ne 'Downloading' -or $state.Percent -le 0)
        $controls.DownloadProgressBar.Value = $state.Percent
        Set-DownloadDetail ([string]$state.Message)
    }
    if (-not $job.Handle.IsCompleted) { return }
    $script:downloadTimer.Stop()
    $result = $null
    $failure = $null
    try {
        $output = @($job.PowerShell.EndInvoke($job.Handle))
        if ($job.PowerShell.HadErrors) { throw (($job.PowerShell.Streams.Error | ForEach-Object { $_.Exception.Message }) -join '；') }
        $result = @($output | Where-Object { $null -ne $_ -and $_.PSObject.Properties['Kind'] }) | Select-Object -Last 1
        if ($null -eq $result) { throw '后台下载没有返回结果。' }
    } catch { $failure = $_.Exception.Message }
    finally {
        try { $job.PowerShell.Dispose() } catch { }
        try { $job.Runspace.Dispose() } catch { }
        try { $job.Cancellation.Dispose() } catch { }
        $script:downloadJob = $null
    }

    $controls.DownloadProgressBar.IsIndeterminate = $false
    $controls.DownloadProgressBar.Visibility = 'Collapsed'
    if ($job.CancelRequested) {
        if ($null -ne $result -and $result.Kind -eq 'Installed') {
            Update-Scan
            Select-InstalledJdk $result.Jdk.Home
            Set-DownloadDetail "JDK $($result.Jdk.Version) 已安装，自动切换已取消。"
        } elseif ($job.Action -eq 'Catalog') {
            Set-DownloadDetail '已取消读取版本目录，可刷新重试。'
        } else {
            Set-DownloadDetail '下载已取消。'
        }
    } elseif ($failure) {
        Set-DownloadDetail $failure $true
    } elseif ($result.Kind -eq 'Catalog') {
        Set-DownloadCatalog $result.Catalog
        $count = $result.Catalog.Count
        if ($count -gt 0) {
            Set-DownloadDetail "已读取 $count 个版本。安装后会备份当前配置并自动切换。"
        } else {
            Set-DownloadDetail '官方目录暂未返回可用版本，可刷新重试。'
        }
    } elseif ($result.Kind -eq 'Installed') {
        $controls.DownloadProgressBar.Visibility = 'Visible'
        $controls.DownloadProgressBar.Value = 100
        Complete-DownloadAndSwitch $result.Jdk $job.Scope
    }
    Update-DownloadActions
    if ($script:downloadClosePending) { $window.Close() }
}

function Show-Plan {
    param($Plan)
    $script:plan = $Plan
    $isRestore = $Plan.Type -eq 'Restore'
    $summary = @()
    $lines = @()
    foreach ($change in $Plan.Changes) {
        $scopeName = if ($change.After.Scope -eq 'User') { '用户' } else { '系统' }
        $oldValue = if ($change.Before.Exists) { $change.Before.Value } else { '(未设置)' }
        $newValue = if ($change.After.Exists) { $change.After.Value } else { '(删除此值)' }
        $lines += "[$scopeName] $($change.After.Name)`r`n原值 [$($change.Before.Kind)]  $oldValue`r`n新值 [$($change.After.Kind)]  $newValue"
        if ($change.After.Name -eq 'JAVA_HOME') {
            $summary += "$scopeName JAVA_HOME  $oldValue → $newValue"
        } elseif ($isRestore) {
            $summary += "$scopeName Path  恢复备份中的配置"
        } else {
            $summary += "$scopeName Path  将目标 JDK 的 bin 移到首位"
        }
    }
    $controls.PreviewTitle.Text = if ($isRestore) { '恢复预览' } else { '切换预览' }
    $controls.PreviewSummary.Text = if ($summary.Count -gt 0) { $summary -join "`r`n" } else { '配置已是目标状态，无需修改。' }
    $controls.PreviewText.Text = $lines -join "`r`n`r`n"
    $controls.PreviewDetails.Visibility = if ($lines.Count -gt 0) { 'Visible' } else { 'Collapsed' }
    $controls.PreviewDetails.IsExpanded = $isRestore
    $controls.ScopeBox.IsEnabled = -not $isRestore
    $controls.SwitchButton.Content = if ($isRestore) { '备份并恢复' } else { '备份并切换' }
    Update-LocalActions
    $needsAdmin = @($Plan.Changes | Where-Object { $_.After.Scope -eq 'Machine' }).Count -gt 0
    if ($Demo) {
        Set-Status '演示模式 · 示例数据，写入和下载均已禁用。'
    } elseif ($needsAdmin -and -not $script:admin) {
        Set-Status '此变更需要管理员权限。重新打开后，请重新选择目标或备份。' $true
    } elseif ($Plan.Changes.Count -gt 0) {
        Set-Status '确认后将备份当前配置，并校验写入结果。'
    } else { Set-Status '配置已是目标状态。' }
}

function Reset-Preview {
    $script:plan = $null
    $controls.ScopeBox.IsEnabled = $true
    $controls.SwitchButton.Content = '备份并切换'
    $controls.TargetTitle.Text = '选择一个 JDK'
    $controls.TargetHome.Text = ''
    $controls.TargetHome.Visibility = 'Collapsed'
    $controls.PreviewTitle.Text = '变更预览'
    $controls.PreviewSummary.Text = '选中本机 JDK 后，可查看 JAVA_HOME 和 Path 的变更。'
    $controls.PreviewDetails.Visibility = 'Collapsed'
    $controls.PreviewDetails.IsExpanded = $false
    $controls.PreviewText.Text = ''
    Update-LocalActions
}

function Update-Plan {
    if ($script:updating) { return }
    Reset-Preview
    $selected = $controls.JdkGrid.SelectedItem
    if ($null -eq $selected) { return }
    $scope = [string]$controls.ScopeBox.SelectedItem.Tag
    $controls.TargetTitle.Text = '切换到 JDK ' + $selected.Version
    $controls.TargetHome.Text = $selected.Home
    $controls.TargetHome.Visibility = 'Visible'
    if ($Demo) {
        $changes = @()
        if ($selected.Home -ne 'C:\Java\jdk-17') {
            $oldPath = '%JAVA_HOME%\bin;%SystemRoot%\System32'
            $changes = @(
                [pscustomobject]@{
                    Before = @{ Exists = $true; Kind = 'String'; Value = 'C:\Java\jdk-17' }
                    After = @{ Exists = $true; Kind = 'String'; Name = 'JAVA_HOME'; Scope = $scope; Value = $selected.Home }
                }
                [pscustomobject]@{
                    Before = @{ Exists = $true; Kind = 'ExpandString'; Value = $oldPath }
                    After = @{ Exists = $true; Kind = 'ExpandString'; Name = 'Path'; Scope = $scope; Value = $selected.Home + '\bin;' + $oldPath }
                }
            )
        }
        Show-Plan ([pscustomobject]@{ Type = 'Switch'; Changes = $changes })
        return
    }
    try {
        Show-Plan (New-JdkSwitchPlan -Home $selected.Home -Scope $scope)
    } catch {
        $controls.PreviewTitle.Text = '无法安全切换'
        $controls.PreviewSummary.Text = $_.Exception.Message
        Set-Status $_.Exception.Message $true
    }
}

function Update-Scan {
    $script:updating = $true
    Reset-Preview
    try {
        if ($Demo) {
            $controls.CurrentHome.Text = 'JAVA_HOME  C:\Java\jdk-17'
            $controls.CurrentJava.Text = '持久化 Path 中的首个 Java：C:\Java\jdk-17\bin\java.exe'
            $controls.JdkGrid.ItemsSource = @(
                [pscustomobject]@{ Version='21.0.6'; Vendor='Eclipse Adoptium'; Architecture='x64'; Home='C:\Java\jdk-21' },
                [pscustomobject]@{ Version='17.0.14'; Vendor='Microsoft'; Architecture='x64'; Home='C:\Java\jdk-17' },
                [pscustomobject]@{ Version='1.8.0_442'; Vendor='Amazon Corretto'; Architecture='x64'; Home='C:\Java\jdk-8' }
            )
            $controls.CountLabel.Text = '已安装（3）'
            $controls.LocalEmpty.Visibility = 'Collapsed'
            Set-Status '演示模式 · 示例数据，写入和下载均已禁用。'
            return
        }
        $snapshot = Get-JdkSnapshot
        $map = Get-JdkVariableMap $snapshot
        $controls.CurrentHome.Text = if ($map.ContainsKey('JAVA_HOME')) { 'JAVA_HOME  ' + $map['JAVA_HOME'] } else { 'JAVA_HOME 尚未设置' }
        $resolution = Get-JdkPathResolution $snapshot
        $controls.CurrentJava.Text = if ($resolution.Uncertain) { 'Path 检查：' + $resolution.Reason } elseif ($resolution.File) { '持久化 Path 中的首个 Java：' + $resolution.File } else { '持久化 Path 中未找到 Java' }
        $items = @(Find-JdkInstallations -Snapshot $snapshot -AdditionalRoots $script:manualRoots)
        $controls.JdkGrid.ItemsSource = $items
        $controls.CountLabel.Text = '已安装（' + $items.Count + '）'
        $controls.LocalEmpty.Visibility = if ($items.Count -eq 0) { 'Visible' } else { 'Collapsed' }
        Set-Status '扫描完成。'
    } catch { Set-Status $_.Exception.Message $true }
    finally { $script:updating = $false }
}

$controls.JdkGrid.Add_SelectionChanged({ Update-Plan })
$controls.ScopeBox.Add_SelectionChanged({ Update-Plan })
$controls.ScanButton.Add_Click({ Update-Scan })
$controls.LayoutRoot.Add_SizeChanged({ Update-Layout })
$controls.MainTabs.Add_SelectionChanged({
    param($sender, $eventArgs)
    if ($eventArgs.Source -eq $sender -and $sender.SelectedItem -eq $controls.DownloadTab -and -not $script:catalogRequested) {
        Start-DownloadWorker -Action Catalog
    }
})
$controls.VersionList.Add_SelectionChanged({
    Update-DownloadSelection
    if (-not $Demo -and $null -eq $script:downloadJob -and $null -ne $controls.VersionList.SelectedItem) {
        $controls.DownloadProgressBar.Visibility = 'Collapsed'
        Set-DownloadDetail '安装后会备份当前配置并自动切换。'
    }
})
$controls.DownloadScopeBox.Add_SelectionChanged({ Update-DownloadActions })
$controls.CatalogButton.Add_Click({ Start-DownloadWorker -Action Catalog })
$controls.CancelDownloadButton.Add_Click({ Stop-DownloadWorker })
$controls.DownloadNowButton.Add_Click({
    $selected = $controls.VersionList.SelectedItem
    $scope = [string]$controls.DownloadScopeBox.SelectedItem.Tag
    if ($null -ne $selected -and ($scope -ne 'Machine' -or $script:admin)) {
        Start-DownloadWorker -Action Install -Major $selected.Major -Scope $scope
    }
})
$window.Add_Closing({
    param($sender, $eventArgs)
    if ($null -ne $script:downloadJob) {
        $eventArgs.Cancel = $true
        $script:downloadClosePending = $true
        Stop-DownloadWorker
    }
})
$controls.AddButton.Add_Click({
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    $dialog.Description = '选择 JDK 根目录（其中应包含 bin 和 release）'
    $dialog.ShowNewFolderButton = $false
    try {
        if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
            $jdk = Get-JdkInstallation $dialog.SelectedPath
            $script:manualRoots += $jdk.Home
            Update-Scan
            Select-InstalledJdk $jdk.Home
        }
    } catch { Set-Status $_.Exception.Message $true }
    finally { $dialog.Dispose() }
})
$controls.SwitchButton.Add_Click({
    if ($null -eq $script:plan -or $null -ne $script:downloadJob) { return }
    $controls.SwitchButton.IsEnabled = $false
    try {
        $result = Invoke-JdkTransaction $script:plan
        $script:plan = $null
        Update-Scan
        if ($result.Changed) {
            $text = '完成，原配置已备份。请重新打开终端与 IDE；若仍使用旧环境，请注销后登录。'
            if ($result.Warning) { $text += ' ' + $result.Warning }
            Set-Status $text
            $controls.PreviewTitle.Text = '操作完成'
            $controls.PreviewSummary.Text = '备份文件：' + $result.Backup
        } else { Set-Status '配置未变化。' }
    } catch {
        $script:plan = $null
        Set-Status $_.Exception.Message $true
        $controls.PreviewTitle.Text = '操作未完成'
        $controls.PreviewSummary.Text = $_.Exception.Message
    }
})
$controls.RestoreButton.Add_Click({
    if ($null -ne $script:downloadJob) { return }
    try {
        $backups = @(Get-JdkBackups)
        if ($backups.Count -eq 0) { Set-Status '暂无备份。首次切换前会自动创建。'; return }
        $dialog = New-Object Microsoft.Win32.OpenFileDialog
        $dialog.Title = '选择本机当前账户的环境备份'
        $dialog.InitialDirectory = $backups[0].DirectoryName
        $dialog.Filter = 'JDK Switcher 备份 (*.json)|*.json'
        if ($dialog.ShowDialog($window)) {
            $restorePlan = New-JdkRestorePlan -File $dialog.FileName
            $controls.MainTabs.SelectedItem = $controls.LocalTab
            $controls.JdkGrid.SelectedIndex = -1
            Reset-Preview
            $controls.TargetTitle.Text = '恢复环境配置'
            Show-Plan $restorePlan
        }
    } catch { Set-Status $_.Exception.Message $true }
})
$controls.BackupButton.Add_Click({
    $directory = Join-Path (Get-JdkDataDirectory) 'backups'
    if (Test-Path -LiteralPath $directory) { Start-Process explorer.exe -ArgumentList ('"' + $directory + '"') }
    else { Set-Status '首次切换后将创建备份目录。' }
})
$elevate = {
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
}
$controls.ElevateButton.Add_Click($elevate)
$controls.DownloadElevateButton.Add_Click($elevate)

$controls.PrivilegeLabel.Text = if ($script:admin) { '管理员权限' } else { '标准权限' }
Update-DownloadActions
if ($Demo) {
    $controls.PrivilegeLabel.Text = '演示模式'
    $controls.AddButton.IsEnabled = $false
    $controls.BackupButton.IsEnabled = $false
    $script:downloadArchitecture = 'x64'
    Set-DownloadCatalog @(
        [pscustomobject]@{ Major = 22; IsLts = $false }
        [pscustomobject]@{ Major = 21; IsLts = $true }
        [pscustomobject]@{ Major = 17; IsLts = $true }
        [pscustomobject]@{ Major = 11; IsLts = $true }
        [pscustomobject]@{ Major = 8; IsLts = $true }
    )
    Set-DownloadDetail '演示目录。安装后会校验下载、备份配置并自动切换。'
}

if ($SmokeTest) {
    # Loads the real XAML, runs the read-only scan and creates a preview only.
    Update-Scan
    if ($controls.JdkGrid.Items.Count -gt 0) {
        if (-not $Demo) { $controls.ScopeBox.SelectedIndex = 1 }
        $controls.JdkGrid.SelectedIndex = 0
        if ($null -eq $script:plan) { throw ('Preview smoke test failed: ' + $controls.PreviewSummary.Text) }
    }
    if ($controls.StatusText.Foreground -eq [Windows.Media.Brushes]::Firebrick -and $controls.JdkGrid.Items.Count -eq 0) { throw $controls.StatusText.Text }
    if ($PreviewImage) {
        if ($PreviewPage -eq 'Download') { $controls.MainTabs.SelectedItem = $controls.DownloadTab }
        $window.Show()
        $window.UpdateLayout()
        $surface = $window.Content
        $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$surface.ActualWidth, [int]$surface.ActualHeight, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($surface)
        $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $stream = [IO.File]::Create([IO.Path]::GetFullPath($PreviewImage))
        try { $encoder.Save($stream) } finally { $stream.Dispose() }
    }
    Write-Output ('UI smoke test passed; discovered installations: ' + $controls.JdkGrid.Items.Count)
    $window.Close()
    return
}
$window.Add_ContentRendered({
    Update-Scan
    if ($Demo) { $controls.JdkGrid.SelectedIndex = 0 }
})
try { [void]$window.ShowDialog() }
catch { if ($EmbeddedHost) { throw }; [void][Windows.MessageBox]::Show($_.Exception.Message, 'JDK Switcher', 'OK', 'Error'); throw }
