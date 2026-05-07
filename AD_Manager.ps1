#
# AD_Manager.ps1 v2.0 - karanik IT Services
# Author : Nikolaos Karanikolas - https://karanik.gr
# Requires: PowerShell 5.1+, RSAT (ActiveDirectory + GroupPolicy)
#            DnsServer + DhcpServer modules are optional
#

#region ── Admin elevation (PS 5.1 compatible) ───────────────────────────────
try {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        $self = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
        if ($self) {
            $psExe = $null
            $c = Get-Command powershell.exe -ErrorAction SilentlyContinue
            if ($c) { $psExe = $c.Source }
            if (-not $psExe) { $c = Get-Command powershell -ErrorAction SilentlyContinue; if ($c) { $psExe = $c.Source } }
            if (-not $psExe) { $c = Get-Command pwsh      -ErrorAction SilentlyContinue; if ($c) { $psExe = $c.Source } }
            if ($psExe) {
                Start-Process -FilePath $psExe -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-File",$self) -Verb RunAs
                exit
            }
        }
    }
} catch { }
#endregion

#region ── STA guard (WPF requires STA) ─────────────────────────────────────
try {
    if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne "STA") {
        $self = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
        $psExe = $null
        $c = Get-Command powershell.exe -ErrorAction SilentlyContinue
        if ($c) { $psExe = $c.Source }
        if (-not $psExe) { $c = Get-Command powershell -ErrorAction SilentlyContinue; if ($c) { $psExe = $c.Source } }
        if (-not $psExe) { $c = Get-Command pwsh       -ErrorAction SilentlyContinue; if ($c) { $psExe = $c.Source } }
        if ($psExe -and $self) {
            Start-Process -FilePath $psExe -ArgumentList @("-NoProfile","-STA","-ExecutionPolicy","Bypass","-File",$self)
            exit
        }
    }
} catch { }
#endregion

try { if ($PSCommandPath) { Unblock-File -Path $PSCommandPath -ErrorAction SilentlyContinue } } catch { }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$Script:AppVersion       = "2.1"
$Script:LogBuffer        = [System.Text.StringBuilder]::new()
$Script:CachedUsers      = $null
$Script:CachedGroups     = $null
$Script:CachedComputers  = $null
$Script:CachedOUs        = $null
$Script:CachedShares     = $null
$Script:CachedPermsCheck = $null
$Script:CachedPwdExpiry  = $null
$Script:CachedInactiveU  = $null
$Script:CachedInactiveC  = $null
$Script:CachedRecycleBin = $null
$Script:CachedDNSZones   = $null
$Script:CachedDHCP       = $null
$Script:DhcpServer       = "localhost"
$ErrorActionPreference   = "SilentlyContinue"

#region ── Logging ────────────────────────────────────────────────────────────
$Script:OutputBuffer = [System.Text.StringBuilder]::new()

# Central output function - writes to Log tab, Output tab, and LogBuffer
function Write-Out {
    param(
        [string]$Text,
        [ValidateSet("INFO","CMD","RESULT","ERROR","WARN","OK","SEP")]
        [string]$Kind = "INFO"
    )
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    # Log tab always gets plain [ts][KIND] line
    $logLine = "[$ts][$Kind] $Text"
    [void]$Script:LogBuffer.AppendLine($logLine)
    [void]$Script:OutputBuffer.AppendLine($logLine)
    # Output tab prefix per kind
    $outLine = switch ($Kind) {
        "CMD"    { "`n[$ts] PS> $Text" }
        "RESULT" { "    $Text" }
        "ERROR"  { "[$ts][ERR] $Text" }
        "WARN"   { "[$ts][WRN] $Text" }
        "OK"     { "[$ts][ OK] $Text" }
        "SEP"    { "`n---- $Text ----" }
        default  { "[$ts][INF] $Text" }
    }
    try {
        if ($null -ne $Global:txtLog) {
            $Global:txtLog.Dispatcher.Invoke([action]{
                $Global:txtLog.AppendText($logLine + "`n")
                $Global:txtLog.ScrollToEnd()
            })
        }
    } catch { }
    try {
        if ($null -ne $Global:txtOutput) {
            $Global:txtOutput.Dispatcher.Invoke([action]{
                $Global:txtOutput.AppendText($outLine + "`n")
                if ($null -ne $Global:chkAutoScroll -and $Global:chkAutoScroll.IsChecked) {
                    $Global:txtOutput.ScrollToEnd()
                }
            })
        }
    } catch { }
}

# Compatibility aliases used throughout the script
function Write-ADLog      { param([string]$Msg, [string]$Level="INFO") Write-Out -Text $Msg -Kind $Level }
function Write-OutputCmd  { param([string]$Cmd)  Write-Out -Text $Cmd  -Kind "CMD"    }
function Write-OutputResult { param([string]$Text) Write-Out -Text $Text -Kind "RESULT" }
#endregion

#region ── Module helpers ─────────────────────────────────────────────────────
function Ensure-ADModule {
    if (Get-Module -Name ActiveDirectory -ErrorAction SilentlyContinue) { return $true }
    try { Import-Module ActiveDirectory -ErrorAction Stop; return $true }
    catch {
        [System.Windows.MessageBox]::Show("ActiveDirectory module (RSAT) not found.`nInstall RSAT first.","Module Missing","OK","Warning")
        return $false
    }
}
function Ensure-GPModule {
    if (Get-Module -Name GroupPolicy -ErrorAction SilentlyContinue) { return $true }
    try { Import-Module GroupPolicy -ErrorAction Stop; return $true }
    catch {
        [System.Windows.MessageBox]::Show("GroupPolicy module (RSAT) not found.","Module Missing","OK","Warning")
        return $false
    }
}
function Ensure-DnsModule {
    if (Get-Module -Name DnsServer -ErrorAction SilentlyContinue) { return $true }
    try { Import-Module DnsServer -ErrorAction Stop; return $true }
    catch {
        [System.Windows.MessageBox]::Show("DnsServer module not available.`nInstall DNS Server Tools via RSAT.","Module Missing","OK","Warning")
        return $false
    }
}
function Ensure-DhcpModule {
    if (Get-Module -Name DhcpServer -ErrorAction SilentlyContinue) { return $true }
    try { Import-Module DhcpServer -ErrorAction Stop; return $true }
    catch {
        [System.Windows.MessageBox]::Show("DhcpServer module not available.`nRun on a DHCP server or install RSAT DHCP tools.","Module Missing","OK","Warning")
        return $false
    }
}
#endregion

#region ── UI Helpers ─────────────────────────────────────────────────────────
function Pick-SavePath {
    param([string]$Default = "export.csv")
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter   = "CSV files (*.csv)|*.csv|Text files (*.txt)|*.txt|All files (*.*)|*.*"
    $dlg.FileName = $Default
    if ($dlg.ShowDialog() -eq "OK") { return $dlg.FileName }
    return $null
}
function Show-Info { param([string]$Msg) [System.Windows.MessageBox]::Show($Msg,"AD Manager","OK","Information") | Out-Null }
function Show-Err  { param([string]$Msg) [System.Windows.MessageBox]::Show($Msg,"Error","OK","Error") | Out-Null }

function Set-Status {
    param([string]$Msg, [int]$Pct = -1)
    try { if ($null -ne $Global:lblStatus) { $Global:lblStatus.Text = $Msg } } catch { }
    try { if ($Pct -ge 0 -and $null -ne $Global:pbMain) { $Global:pbMain.Value = $Pct } } catch { }
    [System.Windows.Forms.Application]::DoEvents()
    Write-ADLog $Msg
}

function Export-ToCSV {
    param($Data, [string]$DefaultName)
    if (-not $Data) { Show-Err "No data to export. Load data first."; return }
    $path = Pick-SavePath -Default $DefaultName
    if (-not $path) { return }
    try {
        $Data | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8
        Show-Info "Exported to:`n$path"
        Write-ADLog "Exported to: $path"
    } catch { Show-Err "Export failed: $($_.Exception.Message)" }
}
#endregion

#region ── XAML ───────────────────────────────────────────────────────────────
[xml]$XAML = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="AD Manager"
    Width="1260" Height="860" MinWidth="960" MinHeight="640"
    WindowStartupLocation="CenterScreen" Background="#F0F2F5">
  <Window.Resources>

    <Style x:Key="AccentBtn" TargetType="Button">
      <Setter Property="Background" Value="#1E6EB5"/><Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderBrush" Value="#1558A0"/><Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,0"/><Setter Property="Height" Value="30"/>
      <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5" Padding="{TemplateBinding Padding}">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#1558A0"/></Trigger>
          <Trigger Property="IsPressed"   Value="True"><Setter TargetName="bd" Property="Background" Value="#0F4580"/></Trigger>
          <Trigger Property="IsEnabled"   Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>

    <Style x:Key="SecBtn" TargetType="Button">
      <Setter Property="Background" Value="#FFFFFF"/><Setter Property="Foreground" Value="#333333"/>
      <Setter Property="BorderBrush" Value="#CCCCCC"/><Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,0"/><Setter Property="Height" Value="30"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5" Padding="{TemplateBinding Padding}">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#F0F0F0"/></Trigger>
          <Trigger Property="IsPressed"   Value="True"><Setter TargetName="bd" Property="Background" Value="#E0E0E0"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>

    <Style x:Key="GreenBtn" TargetType="Button">
      <Setter Property="Background" Value="#2E7D32"/><Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderBrush" Value="#1B5E20"/><Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,0"/><Setter Property="Height" Value="30"/>
      <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5" Padding="{TemplateBinding Padding}">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#1B5E20"/></Trigger>
          <Trigger Property="IsPressed"   Value="True"><Setter TargetName="bd" Property="Background" Value="#154A18"/></Trigger>
          <Trigger Property="IsEnabled"   Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>

    <Style x:Key="DangerBtn" TargetType="Button">
      <Setter Property="Background" Value="#C62828"/><Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderBrush" Value="#8E0000"/><Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,0"/><Setter Property="Height" Value="30"/>
      <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5" Padding="{TemplateBinding Padding}">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#8E0000"/></Trigger>
          <Trigger Property="IsPressed"   Value="True"><Setter TargetName="bd" Property="Background" Value="#6A0000"/></Trigger>
          <Trigger Property="IsEnabled"   Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>

    <Style x:Key="OrangeBtn" TargetType="Button">
      <Setter Property="Background" Value="#E65100"/><Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderBrush" Value="#BF360C"/><Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,0"/><Setter Property="Height" Value="30"/>
      <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5" Padding="{TemplateBinding Padding}">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#BF360C"/></Trigger>
          <Trigger Property="IsPressed"   Value="True"><Setter TargetName="bd" Property="Background" Value="#8C2C09"/></Trigger>
          <Trigger Property="IsEnabled"   Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/><Setter Property="BorderBrush" Value="#DDE1E7"/>
      <Setter Property="BorderThickness" Value="1"/><Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="12"/><Setter Property="Margin" Value="0,0,0,8"/>
    </Style>
    <Style x:Key="SectionHdr" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/><Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#1E6EB5"/><Setter Property="Margin" Value="0,0,0,6"/>
    </Style>
    <Style x:Key="StatLbl" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11"/><Setter Property="Foreground" Value="#555"/>
      <Setter Property="Margin" Value="0,2"/>
    </Style>
    <Style x:Key="StatTBox" TargetType="TextBox">
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="FontSize" Value="11"/><Setter Property="Foreground" Value="#555"/>
      <Setter Property="Margin" Value="0,2"/><Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="BorderThickness" Value="0"/><Setter Property="Background" Value="Transparent"/>
      <Setter Property="Padding" Value="0"/><Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="ADGrid" TargetType="DataGrid">
      <Setter Property="AutoGenerateColumns" Value="True"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="GridLinesVisibility" Value="Horizontal"/>
      <Setter Property="HorizontalGridLinesBrush" Value="#EEEEEE"/>
      <Setter Property="RowBackground" Value="White"/>
      <Setter Property="AlternatingRowBackground" Value="#F8F9FA"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
      <Setter Property="SelectionMode" Value="Extended"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="BorderBrush" Value="#DDE1E7"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="ColumnHeaderHeight" Value="30"/>
      <Setter Property="CanUserSortColumns"   Value="True"/>
      <Setter Property="CanUserResizeColumns" Value="True"/>
      <Setter Property="CanUserReorderColumns" Value="True"/>
    </Style>

    <Style x:Key="FBox" TargetType="TextBox">
      <Setter Property="Height" Value="28"/><Setter Property="Padding" Value="8,0"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="BorderBrush" Value="#CCCCCC"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TextBox">
        <Border Background="White" BorderBrush="{TemplateBinding BorderBrush}"
                BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5">
          <ScrollViewer x:Name="PART_ContentHost" Margin="2,0"/>
        </Border>
      </ControlTemplate></Setter.Value></Setter>
    </Style>

  </Window.Resources>
  <DockPanel>

    <!-- MENU -->
    <Menu DockPanel.Dock="Top" Background="#1E3A5F" Foreground="White" Height="32">
      <Menu.Resources>
        <Style TargetType="MenuItem">
          <Setter Property="Foreground" Value="#FFFFFF"/>
          <Setter Property="Background" Value="#1E3A5F"/>
          <Setter Property="BorderBrush" Value="Transparent"/>
          <Setter Property="BorderThickness" Value="0"/>
          <Setter Property="Padding" Value="14,0"/>
          <Setter Property="Height" Value="32"/>
          <Setter Property="FontSize" Value="12"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="MenuItem">
                <Border x:Name="bd" Background="{TemplateBinding Background}"
                        BorderBrush="{TemplateBinding BorderBrush}"
                        BorderThickness="{TemplateBinding BorderThickness}">
                  <Grid>
                    <ContentPresenter x:Name="hdr" ContentSource="Header"
                                      Margin="{TemplateBinding Padding}"
                                      VerticalAlignment="Center"
                                      RecognizesAccessKey="True"/>
                    <Popup x:Name="PART_Popup" Placement="Bottom"
                           IsOpen="{TemplateBinding IsSubmenuOpen}"
                           AllowsTransparency="True" Focusable="False"
                           PopupAnimation="Fade">
                      <Border Background="#FFFFFF" BorderBrush="#E0E0E0"
                              BorderThickness="1" SnapsToDevicePixels="True"
                              Effect="{x:Null}">
                        <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Cycle"/>
                      </Border>
                    </Popup>
                  </Grid>
                </Border>
                <ControlTemplate.Triggers>
                  <Trigger Property="IsHighlighted" Value="True">
                    <Setter TargetName="bd" Property="Background" Value="#2D5BA0"/>
                  </Trigger>
                  <Trigger Property="IsSubmenuOpen" Value="True">
                    <Setter TargetName="bd" Property="Background" Value="#2D5BA0"/>
                  </Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Style>
        <Style TargetType="Separator">
          <Setter Property="Margin" Value="6,2"/>
          <Setter Property="Background" Value="#E0E0E0"/>
        </Style>
        <Style x:Key="SubMenuItem" TargetType="MenuItem">
          <Setter Property="Foreground" Value="#222222"/>
          <Setter Property="Background" Value="White"/>
          <Setter Property="Padding" Value="14,8"/>
          <Setter Property="FontSize" Value="12"/>
          <Setter Property="BorderThickness" Value="0"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="MenuItem">
                <Border x:Name="bd" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
                  <ContentPresenter ContentSource="Header" RecognizesAccessKey="True"/>
                </Border>
                <ControlTemplate.Triggers>
                  <Trigger Property="IsHighlighted" Value="True">
                    <Setter TargetName="bd" Property="Background" Value="#E8F0FB"/>
                    <Setter Property="Foreground" Value="#1558A0"/>
                  </Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Style>
      </Menu.Resources>
      <MenuItem Header="_File">
        <MenuItem x:Name="menuRefreshAll" Header="Refresh System + Domain" Style="{StaticResource SubMenuItem}"/>
        <Separator/>
        <MenuItem x:Name="menuSaveLog"    Header="Save log..." Style="{StaticResource SubMenuItem}"/>
        <Separator/>
        <MenuItem x:Name="menuSettings"   Header="Settings..." Style="{StaticResource SubMenuItem}"/>
        <Separator/>
        <MenuItem x:Name="menuExit"       Header="Exit" Style="{StaticResource SubMenuItem}"/>
      </MenuItem>
      <MenuItem Header="_Export">
        <MenuItem x:Name="menuExportUsers"     Header="Export AD Users (CSV)" Style="{StaticResource SubMenuItem}"/>
        <MenuItem x:Name="menuExportGroups"    Header="Export AD Groups (CSV)" Style="{StaticResource SubMenuItem}"/>
        <MenuItem x:Name="menuExportComputers" Header="Export AD Computers (CSV)" Style="{StaticResource SubMenuItem}"/>
        <MenuItem x:Name="menuExportOUs"       Header="Export OUs (CSV)" Style="{StaticResource SubMenuItem}"/>
        <MenuItem x:Name="menuExportGPOs"      Header="Export GPOs (CSV)" Style="{StaticResource SubMenuItem}"/>
        <MenuItem x:Name="menuExportShares"    Header="Export Local Shares (CSV)" Style="{StaticResource SubMenuItem}"/>
        <MenuItem x:Name="menuExportPerms"     Header="Export Share Permissions (CSV)" Style="{StaticResource SubMenuItem}"/>
        <Separator/>
        <MenuItem x:Name="menuExportExcel"    Header="Export current view to Excel (.xlsx)" Style="{StaticResource SubMenuItem}"/>
      </MenuItem>
      <MenuItem Header="_Tools">
        <MenuItem x:Name="menuModules"  Header="Module status"      Style="{StaticResource SubMenuItem}"/>
        <MenuItem x:Name="menuHealth"   Header="Run AD Health Check" Style="{StaticResource SubMenuItem}"/>
        <Separator/>
        <MenuItem x:Name="menuDarkMode" Header="Toggle Dark Mode"    Style="{StaticResource SubMenuItem}"/>
        <MenuItem x:Name="menuClearLog" Header="Clear log" Style="{StaticResource SubMenuItem}"/>
      </MenuItem>
      <MenuItem Header="_Help">
        <MenuItem x:Name="menuAbout" Header="About AD Manager" Style="{StaticResource SubMenuItem}"/>
      </MenuItem>
    </Menu>

    <!-- TITLE BAR -->
    <Border DockPanel.Dock="Top" Background="#1E3A5F" Padding="14,6">
      <DockPanel>
        <TextBlock Text="AD Manager" FontSize="18" FontWeight="Bold" Foreground="White" VerticalAlignment="Center"/>
        <Button x:Name="btnDarkMode" Content="&#x263C;" HorizontalAlignment="Right"
                Background="Transparent" Foreground="#90B8E0" BorderThickness="0"
                FontSize="16" Cursor="Hand" Padding="8,0" ToolTip="Switch to Dark mode"
                FontFamily="Segoe UI Symbol"/>
      </DockPanel>
    </Border>

    <!-- STATUS BAR -->
    <StatusBar DockPanel.Dock="Bottom" Background="#E8EDF2" Height="26">
      <StatusBarItem><ProgressBar x:Name="pbMain" Width="160" Height="14" Minimum="0" Maximum="100"/></StatusBarItem>
      <StatusBarItem><TextBlock x:Name="lblStatus" Text="Ready." FontSize="11" Foreground="#555"/></StatusBarItem>
      <StatusBarItem HorizontalAlignment="Right"><TextBlock x:Name="lblDomain" Text="" FontSize="11" Foreground="#777"/></StatusBarItem>
    </StatusBar>

    <!-- TABS -->
    <TabControl x:Name="tabMain" Margin="8,6,8,0" Background="Transparent" BorderBrush="#DDE1E7">
      <TabControl.Resources>
        <Style TargetType="TabItem">
          <Setter Property="Padding" Value="12,6"/><Setter Property="FontSize" Value="11"/>
          <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Foreground" Value="#555"/>
        </Style>
      </TabControl.Resources>

      <!-- TAB 1: SYSTEM -->
      <TabItem Header="System"  ToolTip="OS, RAM, Disk, CPU, BIOS, Network info for this machine">
        <Grid Margin="4">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <Button Grid.Row="0" x:Name="btnRefreshSystem" Content="Refresh System Info" Style="{StaticResource SecBtn}" Width="180" HorizontalAlignment="Left" Margin="0,0,0,4"/>
          <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="0,0,4,0">
            <StackPanel Margin="0,0,4,0">
              <!-- OS -->
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="Operating System" Style="{StaticResource SectionHdr}"/>
                  <UniformGrid Columns="2">
                    <TextBox x:Name="lblOS"          Style="{StaticResource StatTBox}" Text="OS: ..."          IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                    <TextBox x:Name="lblOSBuild"     Style="{StaticResource StatTBox}" Text="Build: ..."       IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                    <TextBox x:Name="lblOSArch"      Style="{StaticResource StatTBox}" Text="Architecture: ..." IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                    <TextBox x:Name="lblInstallDate" Style="{StaticResource StatTBox}" Text="Install date: ..." IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                    <TextBox x:Name="lblHostname"    Style="{StaticResource StatTBox}" Text="Hostname: ..."    IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                    <TextBox x:Name="lblLastBoot"    Style="{StaticResource StatTBox}" Text="Last boot: ..."   IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                    <TextBox x:Name="lblTimeZone"    Style="{StaticResource StatTBox}" Text="Time zone: ..."   IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                    <TextBox x:Name="lblUptime"      Style="{StaticResource StatTBox}" Text="Uptime: ..."      IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                    <TextBox x:Name="lblRegUser"     Style="{StaticResource StatTBox}" Text="Registered: ..."  IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                    <TextBox x:Name="lblDomain2"     Style="{StaticResource StatTBox}" Text="Domain: ..."      IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                  </UniformGrid>
                </StackPanel>
              </Border>
              <!-- Computer / Manufacturer -->
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="Computer / Manufacturer" Style="{StaticResource SectionHdr}"/>
                  <UniformGrid Columns="2">
                    <TextBox x:Name="lblMfg"         Style="{StaticResource StatTBox}" Text="Manufacturer: ..." IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                    <TextBox x:Name="lblModel"        Style="{StaticResource StatTBox}" Text="Model: ..."       IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                    <TextBox x:Name="lblSerial"       Style="{StaticResource StatTBox}" Text="Serial: ..."      IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                    <TextBox x:Name="lblSystemType"   Style="{StaticResource StatTBox}" Text="Type: ..."        IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                  </UniformGrid>
                </StackPanel>
              </Border>
              <!-- BIOS -->
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="BIOS" Style="{StaticResource SectionHdr}"/>
                  <UniformGrid Columns="2">
                    <TextBox x:Name="lblBiosMfg"     Style="{StaticResource StatTBox}" Text="BIOS Mfg: ..."    IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                    <TextBox x:Name="lblBiosVer"      Style="{StaticResource StatTBox}" Text="BIOS Ver: ..."    IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                    <TextBox x:Name="lblBiosSN"       Style="{StaticResource StatTBox}" Text="BIOS SN: ..."     IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                    <TextBox x:Name="lblBiosDate"     Style="{StaticResource StatTBox}" Text="BIOS Date: ..."   IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                  </UniformGrid>
                </StackPanel>
              </Border>
              <!-- CPU -->
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="Processor" Style="{StaticResource SectionHdr}"/>
                  <UniformGrid Columns="2">
                    <TextBox x:Name="lblCpu"          Style="{StaticResource StatTBox}" Text="CPU: ..."         IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                    <TextBox x:Name="lblCpuCores"     Style="{StaticResource StatTBox}" Text="Cores: ..."       IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                    <TextBox x:Name="lblCpuSpeed"     Style="{StaticResource StatTBox}" Text="Max Speed: ..."   IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                    <TextBox x:Name="lblCpuLoad"      Style="{StaticResource StatTBox}" Text="Load: ..."        IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                  </UniformGrid>
                </StackPanel>
              </Border>
              <!-- RAM -->
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="Memory (RAM)" Style="{StaticResource SectionHdr}"/>
                  <UniformGrid Columns="2">
                    <TextBox x:Name="lblRamTotal"     Style="{StaticResource StatTBox}" Text="Total: ..."       IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                    <TextBox x:Name="lblRamAvail"     Style="{StaticResource StatTBox}" Text="Available: ..."   IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                    <TextBox x:Name="lblRamUsed"      Style="{StaticResource StatTBox}" Text="Used: ..."        IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                    <TextBox x:Name="lblRamPct"       Style="{StaticResource StatTBox}" Text="Usage: ..."       IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                  </UniformGrid>
                  <ProgressBar x:Name="pbRam" Height="10" Minimum="0" Maximum="100" Value="0" Margin="0,6,0,0" Foreground="#1E6EB5"/>
                  <DataGrid x:Name="gridRamSticks" Style="{StaticResource ADGrid}" MaxHeight="120" Margin="0,6,0,0"/>
                </StackPanel>
              </Border>
              <!-- Disks -->
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="Disk Drives" Style="{StaticResource SectionHdr}"/>
                  <DataGrid x:Name="gridDisk"      Style="{StaticResource ADGrid}" MaxHeight="160"/>
                  <DataGrid x:Name="gridPhysDisk"  Style="{StaticResource ADGrid}" MaxHeight="120" Margin="0,4,0,0"/>
                </StackPanel>
              </Border>
              <!-- Network -->
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="Network Adapters" Style="{StaticResource SectionHdr}"/>
                  <DataGrid x:Name="gridNetAdapters" Style="{StaticResource ADGrid}" MaxHeight="160"/>
                </StackPanel>
              </Border>
              <!-- Services -->
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <DockPanel Margin="0,0,0,4">
                    <TextBlock Text="Services" Style="{StaticResource SectionHdr}" DockPanel.Dock="Left" VerticalAlignment="Center"/>
                    <TextBox x:Name="txtSvcFilter" Style="{StaticResource FBox}" Width="160" Height="24" DockPanel.Dock="Right" HorizontalAlignment="Right" ToolTip="Filter services"/>
                  </DockPanel>
                  <DataGrid x:Name="gridServices" Style="{StaticResource ADGrid}" MaxHeight="200"/>
                </StackPanel>
              </Border>
              <!-- Startup -->
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="Startup Applications" Style="{StaticResource SectionHdr}"/>
                  <DataGrid x:Name="gridStartup" Style="{StaticResource ADGrid}" MaxHeight="140"/>
                </StackPanel>
              </Border>
              <!-- Running Processes -->
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="Top Processes (by CPU)" Style="{StaticResource SectionHdr}"/>
                  <DataGrid x:Name="gridProcs" Style="{StaticResource ADGrid}" MaxHeight="160"/>
                </StackPanel>
              </Border>

            </StackPanel>
          </ScrollViewer>
        </Grid>
      </TabItem>

      <!-- TAB 2: DOMAIN -->
      <TabItem Header="Domain"  ToolTip="Domain/Forest info, FSMO roles, DCs, Last Logon Heatmap">
        <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="4">
          <StackPanel Margin="4">
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="Domain" Style="{StaticResource SectionHdr}"/>
                <UniformGrid Columns="2" Rows="5">
                  <TextBox x:Name="lblDomainName"    Style="{StaticResource StatTBox}" Text="Name: ..." IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                  <TextBox x:Name="lblDomainDNS"     Style="{StaticResource StatTBox}" Text="DNS Root: ..." IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                  <TextBox x:Name="lblDomainNetbios" Style="{StaticResource StatTBox}" Text="NetBIOS: ..." IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                  <TextBox x:Name="lblDomainMode"    Style="{StaticResource StatTBox}" Text="Functional level: ..." IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                  <TextBox x:Name="lblForestName"    Style="{StaticResource StatTBox}" Text="Forest: ..." IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                  <TextBox x:Name="lblForestMode"    Style="{StaticResource StatTBox}" Text="Forest level: ..." IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                  <TextBox x:Name="lblDomainSID"     Style="{StaticResource StatTBox}" Text="Domain SID: ..." IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                  <TextBox x:Name="lblSites"         Style="{StaticResource StatTBox}" Text="Sites: ..." IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                  <TextBox x:Name="lblUsersCount"    Style="{StaticResource StatTBox}" Text="Users: ..." IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                  <TextBox x:Name="lblGroupsCount"   Style="{StaticResource StatTBox}" Text="Groups: ..." IsReadOnly="True" BorderThickness="0" Background="Transparent"/>
                </UniformGrid>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="FSMO Role Holders" Style="{StaticResource SectionHdr}"/>
                <UniformGrid Columns="2" Rows="5">
                  <TextBlock Style="{StaticResource StatLbl}" Text="PDC Emulator:"/>        <TextBox x:Name="lblPDC" IsReadOnly="True" BorderThickness="0" Background="Transparent"    Style="{StaticResource StatTBox}" Text="..."/>
                  <TextBlock Style="{StaticResource StatLbl}" Text="RID Master:"/>           <TextBox x:Name="lblRID" IsReadOnly="True" BorderThickness="0" Background="Transparent"    Style="{StaticResource StatTBox}" Text="..."/>
                  <TextBlock Style="{StaticResource StatLbl}" Text="Infrastructure Master:"/><TextBox x:Name="lblInfra" IsReadOnly="True" BorderThickness="0" Background="Transparent"  Style="{StaticResource StatTBox}" Text="..."/>
                  <TextBlock Style="{StaticResource StatLbl}" Text="Schema Master:"/>        <TextBox x:Name="lblSchema" IsReadOnly="True" BorderThickness="0" Background="Transparent" Style="{StaticResource StatTBox}" Text="..."/>
                  <TextBlock Style="{StaticResource StatLbl}" Text="Domain Naming Master:"/> <TextBox x:Name="lblDNM" IsReadOnly="True" BorderThickness="0" Background="Transparent"    Style="{StaticResource StatTBox}" Text="..."/>
                </UniformGrid>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="Domain Controllers" Style="{StaticResource SectionHdr}"/>
                <DataGrid x:Name="gridDCs" Style="{StaticResource ADGrid}" MaxHeight="180"/>
              </StackPanel>
            </Border>
            <Button x:Name="btnRefreshDomain" Content="Refresh Domain Info" Style="{StaticResource SecBtn}" Width="180" HorizontalAlignment="Left" Margin="0,0,8,0"/>
            <Border Style="{StaticResource Card}" Margin="0,8,0,0">
              <StackPanel>
                <DockPanel Margin="0,0,0,8">
                  <TextBlock Text="Last Logon Activity Heatmap" Style="{StaticResource SectionHdr}" DockPanel.Dock="Left" VerticalAlignment="Center"/>
                  <Button x:Name="btnLoadHeatmap" Content="Load Heatmap" Style="{StaticResource AccentBtn}" HorizontalAlignment="Right" DockPanel.Dock="Right"/>
                </DockPanel>
                <TextBlock x:Name="lblHeatmapInfo" Text="Shows enabled users grouped by days since last logon." FontSize="11" Foreground="#777" Margin="0,0,0,8"/>
                <ItemsControl x:Name="icHeatmap">
                  <ItemsControl.ItemsPanel>
                    <ItemsPanelTemplate><WrapPanel/></ItemsPanelTemplate>
                  </ItemsControl.ItemsPanel>
                </ItemsControl>
                <Border x:Name="borderHeatmapDetail" Visibility="Collapsed" Margin="0,8,0,0" BorderBrush="#DDE1E7" BorderThickness="1" CornerRadius="6">
                  <StackPanel>
                    <DockPanel Margin="8,6">
                      <TextBlock x:Name="lblHeatmapDetailTitle" FontSize="12" FontWeight="SemiBold" Foreground="#1E3A5F" DockPanel.Dock="Left" VerticalAlignment="Center"/>
                      <Button x:Name="btnHeatmapDetailClose" Content="X" Width="24" Height="24" HorizontalAlignment="Right" DockPanel.Dock="Right"
                              Background="Transparent" BorderThickness="0" FontSize="12" FontWeight="Bold" Cursor="Hand" Foreground="#888"/>
                    </DockPanel>
                    <DataGrid x:Name="gridHeatmapDetail" Style="{StaticResource ADGrid}" MaxHeight="200" IsReadOnly="True" Margin="4,0,4,8"/>
                  </StackPanel>
                </Border>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <!-- TAB 3: OU TREE -->
      <TabItem Header="OU Tree" ToolTip="Browse and export Organizational Units">
        <Grid Margin="4">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,6">
            <Button x:Name="btnLoadOUs"      Content="Load OU Tree"  Style="{StaticResource AccentBtn}" Margin="0,0,8,0"/>
            <Button x:Name="btnExportOUsBtn" Content="Export CSV"    Style="{StaticResource GreenBtn}"  Margin="0,0,8,0"/>
            <TextBox x:Name="txtOUFilter"    Style="{StaticResource FBox}" Width="200" Margin="0,0,6,0" ToolTip="Filter by name"/>
            <TextBlock Text="Filter" VerticalAlignment="Center" FontSize="11" Foreground="#555"/>
          </StackPanel>
          <Border Grid.Row="1" Style="{StaticResource Card}" Padding="4">
            <TreeView x:Name="treeOU" FontSize="12">
              <TreeView.ContextMenu>
                <ContextMenu>
                  <MenuItem x:Name="ctxOUCopy" Header="Copy OU path"/>
                  <MenuItem x:Name="ctxOULoadUsers" Header="Load users in this OU"/>
                </ContextMenu>
              </TreeView.ContextMenu>
            </TreeView>
          </Border>
          <TextBlock Grid.Row="2" x:Name="lblOUCount" Text="" FontSize="11" Foreground="#777" Margin="2,2,0,0"/>
        </Grid>
      </TabItem>

      <!-- TAB 4: SHARES -->
      <TabItem Header="Shares"  ToolTip="Local shares + deep NTFS permission scanner">
        <Grid Margin="4">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="160" MinHeight="60"/>
            <RowDefinition Height="4"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="4"/>
            <RowDefinition Height="*" MinHeight="60"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,6">
            <Button x:Name="btnLoadShares"      Content="Load Shares"          Style="{StaticResource AccentBtn}" Margin="0,0,8,0"/>
            <Button x:Name="btnExportSharesBtn" Content="Export Shares CSV"    Style="{StaticResource GreenBtn}"  Margin="0,0,8,0"/>
            <Button x:Name="btnExportPermsBtn"  Content="Export Full Perms CSV" Style="{StaticResource GreenBtn}"/>
          </StackPanel>
          <Border Grid.Row="1" Style="{StaticResource Card}" Padding="4">
            <DataGrid x:Name="gridShares" Style="{StaticResource ADGrid}"/>
          </Border>
          <GridSplitter Grid.Row="2" Height="4" HorizontalAlignment="Stretch" VerticalAlignment="Center" Background="#CCD3DC" ShowsPreview="True" ResizeBehavior="PreviousAndNext"/>
          <Border Grid.Row="3" Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Check User / Group Permissions on Shares" Style="{StaticResource SectionHdr}"/>
              <TextBlock Text="Scan a specific folder tree (instead of all shares)" FontSize="11" Foreground="#777" Margin="0,0,0,4"/>
              <!-- Row 1: user + depth + action buttons -->
              <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                <TextBox x:Name="txtCheckUser" Style="{StaticResource FBox}" Width="170" Margin="0,0,6,0" ToolTip="SAMAccountName or DOMAIN\user"/>
                <Button x:Name="btnPickUsers"    Content="Users"            Style="{StaticResource SecBtn}" Margin="0,0,4,0" ToolTip="Load all AD users - select one or more to fill the filter box"/>
                <Button x:Name="btnPickGroups"   Content="Groups"           Style="{StaticResource SecBtn}" Margin="0,0,8,0" ToolTip="Load all AD groups - select one or more to fill the filter box"/>
                <Button x:Name="btnBrowseFolder" Content="Browse Folder..."  Style="{StaticResource SecBtn}" Margin="0,0,8,0" ToolTip="Scan a specific folder instead of all shares"/>
                <TextBlock Text="Depth:" VerticalAlignment="Center" FontSize="11" Margin="0,0,4,0" ToolTip="Subfolder levels (0=root, 2=default, 4=deep)"/>
                <TextBox x:Name="txtScanDepth" Style="{StaticResource FBox}" Width="36" Text="2" Margin="0,0,8,0"/>
                <Button x:Name="btnCheckPerms" Content="Check NTFS Permissions" Style="{StaticResource AccentBtn}" Margin="0,0,8,0"/>
                <Button x:Name="btnStopScan"  Content="&#x25A0; Stop" Style="{StaticResource DangerBtn}" Visibility="Collapsed" ToolTip="Διακοπή scan"/>
              </StackPanel>
              <!-- Row 2: scan options checkboxes -->
              <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
                <CheckBox x:Name="chkSkipSystemFolders" Content="Skip system folders ($Recycle.Bin, System Vol. Info)" IsChecked="True"
                          FontSize="11" VerticalAlignment="Center" Margin="0,0,16,0"
                          ToolTip="Skips: $Recycle.Bin, $RECYCLE.BIN, System Volume Information, DfsrPrivate, $SysReset, Recovery"/>
                <CheckBox x:Name="chkSkipAdminShares"   Content="Skip admin shares (ADMIN$, C$, D$, IPC$)" IsChecked="True"
                          FontSize="11" VerticalAlignment="Center" Margin="0,0,16,0"
                          ToolTip="Skips shares ending in $ - ADMIN$, C$, D$, IPC$, PRINT$, etc."/>
                <CheckBox x:Name="chkLimitResults"      Content="Warn at 1000+ results" IsChecked="True"
                          FontSize="11" VerticalAlignment="Center"
                          ToolTip="Shows a Yes/No dialog when results exceed 1000 entries during scan"/>
              </StackPanel>
            </StackPanel>
          </Border>
          <GridSplitter Grid.Row="4" Height="4" HorizontalAlignment="Stretch" VerticalAlignment="Center" Background="#CCD3DC" ShowsPreview="True" ResizeBehavior="PreviousAndNext"/>
          <Border Grid.Row="5" Style="{StaticResource Card}" Padding="4">
            <DataGrid x:Name="gridPerms" Style="{StaticResource ADGrid}"/>
          </Border>
          <Button Grid.Row="6" x:Name="btnExportPermsResult" Content="Export Checked Permissions CSV"
                  Style="{StaticResource GreenBtn}" HorizontalAlignment="Left" Width="260" Margin="0,4,0,0"/>
        </Grid>
      </TabItem>

      <!-- TAB 5: USERS -->
      <TabItem Header="Users"   ToolTip="AD users: filter, export, enable/disable, reset pwd, member-of">
        <Grid Margin="4">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="4"/>
            <RowDefinition Height="*" MinHeight="80"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <!-- Row 0: Toolbar -->
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,6">
            <Button x:Name="btnLoadUsers"        Content="Load"         Style="{StaticResource AccentBtn}" Margin="0,0,6,0" ToolTip="Load all AD users (F5)"/>
            <Button x:Name="btnExportUsersBtn"   Content="Export CSV"   Style="{StaticResource GreenBtn}"  Margin="0,0,6,0" ToolTip="Export to CSV (Ctrl+E)"/>
            <Button x:Name="btnExportUsersXlsx"  Content="Export XLSX"  Style="{StaticResource GreenBtn}"  Margin="0,0,10,0" ToolTip="Export to Excel with formatting"/>
            <Button x:Name="btnEnableSelected"   Content="Enable"       Style="{StaticResource AccentBtn}" Margin="0,0,4,0"  ToolTip="Enable selected accounts"/>
            <Button x:Name="btnDisableSelected"  Content="Disable"      Style="{StaticResource OrangeBtn}" Margin="0,0,6,0"  ToolTip="Disable selected accounts"/>
            <Button x:Name="btnResetPassword"    Content="Reset Pwd"    Style="{StaticResource OrangeBtn}" Margin="0,0,4,0"  ToolTip="Reset password for selected user"/>
            <Button x:Name="btnUnlockAccount"    Content="Unlock"       Style="{StaticResource GreenBtn}"  Margin="0,0,6,0"  ToolTip="Unlock selected locked-out account"/>
            <Button x:Name="btnMemberOf"         Content="Member-Of"    Style="{StaticResource SecBtn}"    Margin="0,0,6,0"  ToolTip="Show groups of selected user"/>
            <Button x:Name="btnUserAudit"        Content="Auth Audit"   Style="{StaticResource SecBtn}"    Margin="0,0,6,0"  ToolTip="Show authentication events for selected user from all DCs (logons, Kerberos, NTLM, lockouts)"/>
            <Button x:Name="btnShowHeatmap"      Content="Heatmap"      Style="{StaticResource SecBtn}"    Margin="0,0,10,0" ToolTip="Last logon activity heatmap"/>
            <TextBox x:Name="txtUserLiveFilter"  Style="{StaticResource FBox}" Width="160" Margin="0,0,4,0" ToolTip="Live filter - type to filter results instantly"/>
            <TextBlock Text="Filter" VerticalAlignment="Center" FontSize="11" Foreground="#555" Margin="0,0,8,0"/>
            <CheckBox x:Name="chkDisabledUsers"  Content="Disabled only" VerticalAlignment="Center" FontSize="11" ToolTip="Show only disabled accounts"/>
            <TextBox x:Name="txtUserFilter" Width="0" Visibility="Collapsed"/>
          </StackPanel>
          <!-- Row 1: Member-Of panel (collapsible) -->
          <Border Grid.Row="1" Style="{StaticResource Card}" Padding="6">
            <StackPanel x:Name="panelMemberOf" Visibility="Collapsed">
              <TextBlock x:Name="lblMemberOfTitle" Text="Groups for user:" Style="{StaticResource SectionHdr}"/>
              <DataGrid x:Name="gridMemberOf" Style="{StaticResource ADGrid}" MaxHeight="140" IsReadOnly="True"/>
            </StackPanel>
          </Border>
          <!-- Row 2: Heatmap panel (collapsible) -->
          <Border Grid.Row="2" Style="{StaticResource Card}" Padding="6" x:Name="panelUsersHeatmap" Visibility="Collapsed">
            <StackPanel>
              <DockPanel Margin="0,0,0,6">
                <TextBlock Text="Last Logon Heatmap" Style="{StaticResource SectionHdr}" DockPanel.Dock="Left" VerticalAlignment="Center"/>
                <TextBlock x:Name="lblUsersHeatmapInfo" Text="" FontSize="11" Foreground="#777" DockPanel.Dock="Right" VerticalAlignment="Center" HorizontalAlignment="Right"/>
              </DockPanel>
              <ItemsControl x:Name="icUsersHeatmap">
                <ItemsControl.ItemsPanel><ItemsPanelTemplate><WrapPanel/></ItemsPanelTemplate></ItemsControl.ItemsPanel>
              </ItemsControl>
              <Border x:Name="borderUsersHeatmapDetail" Visibility="Collapsed" Margin="0,8,0,0" BorderBrush="#DDE1E7" BorderThickness="1" CornerRadius="6">
                <StackPanel>
                  <DockPanel Margin="8,6">
                    <TextBlock x:Name="lblUsersHeatmapDetailTitle" FontSize="12" FontWeight="SemiBold" Foreground="#1E3A5F" DockPanel.Dock="Left" VerticalAlignment="Center"/>
                    <Button x:Name="btnUsersHeatmapDetailClose" Content="X" Width="24" Height="24" HorizontalAlignment="Right" DockPanel.Dock="Right"
                            Background="Transparent" BorderThickness="0" FontSize="12" FontWeight="Bold" Cursor="Hand" Foreground="#888"/>
                  </DockPanel>
                  <DataGrid x:Name="gridUsersHeatmapDetail" Style="{StaticResource ADGrid}" MaxHeight="200" IsReadOnly="True" Margin="4,0,4,8"/>
                </StackPanel>
              </Border>
            </StackPanel>
          </Border>
          <!-- Splitter -->
          <GridSplitter Grid.Row="3" Height="4" HorizontalAlignment="Stretch" VerticalAlignment="Center" Background="#CCD3DC" ShowsPreview="True" ResizeBehavior="PreviousAndNext"/>
          <!-- Row 4: Main grid -->
          <Border Grid.Row="4" Style="{StaticResource Card}" Padding="4">
            <DataGrid x:Name="gridUsers" Style="{StaticResource ADGrid}" SelectionMode="Extended" IsReadOnly="True">
              <DataGrid.ContextMenu>
                <ContextMenu>
                  <MenuItem x:Name="ctxCopyCell"    Header="Copy cell value"  />
                  <MenuItem x:Name="ctxCopyRow"     Header="Copy row (tab-sep)"/>
                  <Separator/>
                  <MenuItem x:Name="ctxUserDetail"  Header="Show user details..."/>
                </ContextMenu>
              </DataGrid.ContextMenu>
            </DataGrid>
          </Border>
          <!-- Row 4: Row count -->
          <TextBlock Grid.Row="5" x:Name="lblUsersRowCount" Text="" FontSize="11" Foreground="#777" Margin="2,2,0,0"/>
        </Grid>
      </TabItem>

      <!-- TAB 6: GROUPS -->
      <TabItem Header="Groups"  ToolTip="AD groups + optional nested member expansion">
        <Grid Margin="4">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,6">
            <Button x:Name="btnLoadGroups"      Content="Load"          Style="{StaticResource AccentBtn}" Margin="0,0,8,0"/>
            <Button x:Name="btnExportGroupsBtn" Content="Export CSV"    Style="{StaticResource GreenBtn}"  Margin="0,0,8,0"/>
            <CheckBox x:Name="chkNestedMembers" Content="Include nested members" VerticalAlignment="Center" FontSize="11" Margin="0,0,14,0"/>
            <TextBox x:Name="txtGroupFilter"    Style="{StaticResource FBox}" Width="180" Margin="0,0,6,0"/>
            <TextBlock Text="Filter" VerticalAlignment="Center" FontSize="11" Foreground="#555"/>
          </StackPanel>
          <Border Grid.Row="1" Style="{StaticResource Card}" Padding="4">
            <DataGrid x:Name="gridGroups" Style="{StaticResource ADGrid}">
              <DataGrid.ContextMenu>
                <ContextMenu>
                  <MenuItem x:Name="ctxCopyCellG"    Header="Copy cell value"/>
                  <MenuItem x:Name="ctxCopyRowG"     Header="Copy row (tab-sep)"/>
                  <Separator/>
                  <MenuItem x:Name="ctxGroupDetails" Header="Group Details / Members..."/>
                </ContextMenu>
              </DataGrid.ContextMenu>
            </DataGrid>
          </Border>
          <TextBlock Grid.Row="2" x:Name="lblGroupsRowCount" Text="" FontSize="11" Foreground="#777" Margin="2,2,0,0"/>
        </Grid>
      </TabItem>

      <!-- TAB 7: COMPUTERS -->
      <TabItem Header="Computers" ToolTip="AD computer accounts">
        <Grid Margin="4">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,6">
            <Button x:Name="btnLoadComputers"      Content="Load"        Style="{StaticResource AccentBtn}" Margin="0,0,8,0" ToolTip="Load all AD computers (F5)"/>
            <Button x:Name="btnExportComputersBtn" Content="Export CSV"  Style="{StaticResource GreenBtn}"  Margin="0,0,8,0"/>
            <Button x:Name="btnComputerHeatmap"    Content="Heatmap"     Style="{StaticResource SecBtn}"    Margin="0,0,10,0" ToolTip="Last logon activity heatmap for computers"/>
            <TextBox x:Name="txtComputerFilter"    Style="{StaticResource FBox}" Width="180" Margin="0,0,6,0" ToolTip="Filter by name"/>
            <TextBlock Text="Filter" VerticalAlignment="Center" FontSize="11" Foreground="#555"/>
          </StackPanel>
          <!-- Computers Heatmap panel -->
          <Border Grid.Row="1" Style="{StaticResource Card}" Padding="6" x:Name="panelComputerHeatmap" Visibility="Collapsed">
            <StackPanel>
              <DockPanel Margin="0,0,0,6">
                <TextBlock Text="Last Logon Heatmap - Computers" Style="{StaticResource SectionHdr}" DockPanel.Dock="Left" VerticalAlignment="Center"/>
                <TextBlock x:Name="lblComputerHeatmapInfo" Text="" FontSize="11" Foreground="#777" DockPanel.Dock="Right" VerticalAlignment="Center" HorizontalAlignment="Right"/>
              </DockPanel>
              <ItemsControl x:Name="icComputerHeatmap">
                <ItemsControl.ItemsPanel><ItemsPanelTemplate><WrapPanel/></ItemsPanelTemplate></ItemsControl.ItemsPanel>
              </ItemsControl>
              <Border x:Name="borderComputerHeatmapDetail" Visibility="Collapsed" Margin="0,8,0,0" BorderBrush="#DDE1E7" BorderThickness="1" CornerRadius="6">
                <StackPanel>
                  <DockPanel Margin="8,6">
                    <TextBlock x:Name="lblComputerHeatmapDetailTitle" FontSize="12" FontWeight="SemiBold" Foreground="#1E3A5F" DockPanel.Dock="Left" VerticalAlignment="Center"/>
                    <Button x:Name="btnComputerHeatmapDetailClose" Content="X" Width="24" Height="24" HorizontalAlignment="Right" DockPanel.Dock="Right"
                            Background="Transparent" BorderThickness="0" FontSize="12" FontWeight="Bold" Cursor="Hand" Foreground="#888"/>
                  </DockPanel>
                  <DataGrid x:Name="gridComputerHeatmapDetail" Style="{StaticResource ADGrid}" MaxHeight="200" IsReadOnly="True" Margin="4,0,4,8"/>
                </StackPanel>
              </Border>
            </StackPanel>
          </Border>
          <Border Grid.Row="2" Style="{StaticResource Card}" Padding="4">
            <DataGrid x:Name="gridComputers" Style="{StaticResource ADGrid}">
              <DataGrid.ContextMenu>
                <ContextMenu>
                  <MenuItem x:Name="ctxCopyCellC"  Header="Copy cell value"/>
                  <MenuItem x:Name="ctxCopyRowC"   Header="Copy row (tab-sep)"/>
                  <Separator/>
                  <MenuItem x:Name="ctxCompPing" Header="Ping (continuous)..." ToolTip="Opens cmd with continuous ping to the selected computer"/>
                  <MenuItem x:Name="ctxCompRDP"  Header="RDP connect..."      ToolTip="Opens Remote Desktop to the selected computer"/>
                </ContextMenu>
              </DataGrid.ContextMenu>
            </DataGrid>
          </Border>
          <TextBlock Grid.Row="3" x:Name="lblComputersRowCount" Text="" FontSize="11" Foreground="#777" Margin="2,2,0,0"/>
        </Grid>
      </TabItem>

      <!-- TAB 8: GPOs -->
      <TabItem Header="GPOs"    ToolTip="Group Policy Objects + GPO-to-OU link viewer">
        <Grid Margin="4">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="180"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,6">
            <Button x:Name="btnLoadGPOs"      Content="Load GPOs"        Style="{StaticResource AccentBtn}" Margin="0,0,8,0"/>
            <Button x:Name="btnExportGPOsBtn" Content="Export CSV"       Style="{StaticResource GreenBtn}"  Margin="0,0,8,0"/>
            <Button x:Name="btnLoadGPOLinks"  Content="GPO Link Viewer"  Style="{StaticResource SecBtn}"/>
          </StackPanel>
          <Border Grid.Row="1" Style="{StaticResource Card}" Padding="4">
            <DataGrid x:Name="gridGPOs" Style="{StaticResource ADGrid}"/>
          </Border>
          <TextBlock Grid.Row="2" Text="GPO Links (which GPO is linked to which OU):" Style="{StaticResource SectionHdr}" Margin="4,4,0,4"/>
          <Border Grid.Row="3" Style="{StaticResource Card}" Padding="4">
            <DataGrid x:Name="gridGPOLinks" Style="{StaticResource ADGrid}"/>
          </Border>
        </Grid>
      </TabItem>

      <!-- TAB 9: PASSWORD EXPIRY -->
      <TabItem Header="Pwd Expiry" ToolTip="Users whose password expires within N days">
        <Grid Margin="4">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <Border Grid.Row="0" Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Password Expiry Report" Style="{StaticResource SectionHdr}"/>
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="Show users expiring in the next" VerticalAlignment="Center" FontSize="12" Margin="0,0,8,0"/>
                <TextBox x:Name="txtPwdDays" Style="{StaticResource FBox}" Width="55" Text="30" Margin="0,0,8,0"/>
                <TextBlock Text="days" VerticalAlignment="Center" FontSize="12" Margin="0,0,14,0"/>
                <Button x:Name="btnPwdExpiry"       Content="Run Report"  Style="{StaticResource AccentBtn}" Margin="0,0,8,0"/>
                <Button x:Name="btnExportPwdExpiry" Content="Export CSV"  Style="{StaticResource GreenBtn}"/>
              </StackPanel>
            </StackPanel>
          </Border>
          <Border Grid.Row="1" Style="{StaticResource Card}" Padding="4">
            <DataGrid x:Name="gridPwdExpiry" Style="{StaticResource ADGrid}"/>
          </Border>
        </Grid>
      </TabItem>

      <!-- TAB 10: INACTIVE -->
      <TabItem Header="Inactive" ToolTip="Users and computers with no logon in N days">
        <Grid Margin="4">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="180"/>
          </Grid.RowDefinitions>
          <Border Grid.Row="0" Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Inactive Accounts" Style="{StaticResource SectionHdr}"/>
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="Last logon older than" VerticalAlignment="Center" FontSize="12" Margin="0,0,8,0"/>
                <TextBox x:Name="txtInactiveDays" Style="{StaticResource FBox}" Width="55" Text="90" Margin="0,0,8,0"/>
                <TextBlock Text="days" VerticalAlignment="Center" FontSize="12" Margin="0,0,14,0"/>
                <Button x:Name="btnLoadInactive"     Content="Find Inactive Users"     Style="{StaticResource AccentBtn}" Margin="0,0,8,0"/>
                <Button x:Name="btnLoadInactiveComp" Content="Find Inactive Computers" Style="{StaticResource SecBtn}"    Margin="0,0,8,0"/>
                <Button x:Name="btnExportInactive"   Content="Export Users CSV"        Style="{StaticResource GreenBtn}"/>
              </StackPanel>
            </StackPanel>
          </Border>
          <Border Grid.Row="1" Style="{StaticResource Card}" Padding="4">
            <DataGrid x:Name="gridInactiveUsers" Style="{StaticResource ADGrid}"/>
          </Border>
          <TextBlock Grid.Row="2" Text="Inactive Computers" Style="{StaticResource SectionHdr}" Margin="4,4,0,4"/>
          <Border Grid.Row="3" Style="{StaticResource Card}" Padding="4">
            <DataGrid x:Name="gridInactiveComp" Style="{StaticResource ADGrid}"/>
          </Border>
        </Grid>
      </TabItem>

      <!-- TAB 11: RECYCLE BIN -->
      <TabItem Header="Recycle Bin" ToolTip="Deleted AD objects (requires Recycle Bin feature enabled)">
        <Grid Margin="4">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,6">
            <Button x:Name="btnLoadRecycleBin"   Content="Load Deleted Objects" Style="{StaticResource AccentBtn}" Margin="0,0,8,0"/>
            <Button x:Name="btnExportRecycleBin" Content="Export CSV"           Style="{StaticResource GreenBtn}"/>
          </StackPanel>
          <Border Grid.Row="1" Style="{StaticResource Card}" Padding="4">
            <DataGrid x:Name="gridRecycleBin" Style="{StaticResource ADGrid}"/>
          </Border>
        </Grid>
      </TabItem>

      <!-- TAB 12: DNS -->
      <TabItem Header="DNS Zones" ToolTip="DNS zones and resource records (requires DnsServer module)">
        <Grid Margin="4">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="200"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,6">
            <Button x:Name="btnLoadDNS"    Content="Load DNS Zones"    Style="{StaticResource AccentBtn}" Margin="0,0,8,0"/>
            <Button x:Name="btnExportDNS"  Content="Export Zones CSV"  Style="{StaticResource GreenBtn}"  Margin="0,0,8,0"/>
            <Button x:Name="btnLoadDNSRec" Content="Load Zone Records" Style="{StaticResource SecBtn}"    ToolTip="Select a zone above first"/>
          </StackPanel>
          <Border Grid.Row="1" Style="{StaticResource Card}" Padding="4">
            <DataGrid x:Name="gridDNSZones" Style="{StaticResource ADGrid}"/>
          </Border>
          <TextBlock Grid.Row="2" Text="Zone Records:" Style="{StaticResource SectionHdr}" Margin="4,4,0,4"/>
          <Border Grid.Row="3" Style="{StaticResource Card}" Padding="4">
            <DataGrid x:Name="gridDNSRecords" Style="{StaticResource ADGrid}"/>
          </Border>
        </Grid>
      </TabItem>

      <!-- TAB 13: DHCP -->
      <TabItem Header="DHCP"    ToolTip="DHCP scopes and active leases (requires DhcpServer module)">
        <Grid Margin="4">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="200"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,6">
            <TextBlock Text="DHCP Server:" VerticalAlignment="Center" FontSize="12" Margin="0,0,8,0"/>
            <TextBox x:Name="txtDhcpServer" Style="{StaticResource FBox}" Width="190" Margin="0,0,8,0" ToolTip="Hostname or IP (blank = localhost)"/>
            <Button x:Name="btnLoadDHCP"   Content="Load Scopes"  Style="{StaticResource AccentBtn}" Margin="0,0,8,0"/>
            <Button x:Name="btnExportDHCP" Content="Export CSV"   Style="{StaticResource GreenBtn}"  Margin="0,0,8,0"/>
            <Button x:Name="btnLoadLeases" Content="Load Leases"  Style="{StaticResource SecBtn}"    ToolTip="Select a scope above first"/>
          </StackPanel>
          <Border Grid.Row="1" Style="{StaticResource Card}" Padding="4">
            <DataGrid x:Name="gridDHCP" Style="{StaticResource ADGrid}"/>
          </Border>
          <TextBlock Grid.Row="2" Text="Active Leases:" Style="{StaticResource SectionHdr}" Margin="4,4,0,4"/>
          <Border Grid.Row="3" Style="{StaticResource Card}" Padding="4">
            <DataGrid x:Name="gridLeases" Style="{StaticResource ADGrid}"/>
          </Border>
        </Grid>
      </TabItem>

      <!-- TAB: STALE COMPUTERS -->
      <TabItem Header="Stale PCs" ToolTip="Computers whose machine account password has not changed in N days">
        <Grid Margin="4">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <Border Grid.Row="0" Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Stale Computer Accounts" Style="{StaticResource SectionHdr}"/>
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="No password change in more than" VerticalAlignment="Center" FontSize="12" Margin="0,0,8,0"/>
                <TextBox x:Name="txtStaleDays" Style="{StaticResource FBox}" Width="55" Text="30" Margin="0,0,8,0"/>
                <TextBlock Text="days" VerticalAlignment="Center" FontSize="12" Margin="0,0,14,0"/>
                <Button x:Name="btnLoadStale"   Content="Find Stale Computers" Style="{StaticResource AccentBtn}" Margin="0,0,8,0"/>
                <Button x:Name="btnExportStale" Content="Export CSV"           Style="{StaticResource GreenBtn}"/>
              </StackPanel>
            </StackPanel>
          </Border>
          <Border Grid.Row="1" Style="{StaticResource Card}" Padding="4">
            <DataGrid x:Name="gridStale" Style="{StaticResource ADGrid}"/>
          </Border>
        </Grid>
      </TabItem>

      <!-- TAB: GROUP DIFF -->
      <TabItem Header="Group Diff" ToolTip="Compare group memberships between two AD users">
        <Grid Margin="4">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <Border Grid.Row="0" Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Group Membership Diff - compare two users" Style="{StaticResource SectionHdr}"/>
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="User A:" VerticalAlignment="Center" FontSize="12" Margin="0,0,6,0"/>
                <TextBox x:Name="txtDiffUserA" Style="{StaticResource FBox}" Width="160" Margin="0,0,6,0" ToolTip="SAMAccountName"/>
                <Button x:Name="btnPickDiffA"  Content="Pick" Style="{StaticResource SecBtn}" Margin="0,0,14,0"/>
                <TextBlock Text="User B:" VerticalAlignment="Center" FontSize="12" Margin="0,0,6,0"/>
                <TextBox x:Name="txtDiffUserB" Style="{StaticResource FBox}" Width="160" Margin="0,0,6,0" ToolTip="SAMAccountName"/>
                <Button x:Name="btnPickDiffB"  Content="Pick" Style="{StaticResource SecBtn}" Margin="0,0,14,0"/>
                <Button x:Name="btnRunDiff"    Content="Compare" Style="{StaticResource AccentBtn}" Margin="0,0,8,0"/>
                <Button x:Name="btnExportDiff" Content="Export CSV" Style="{StaticResource GreenBtn}"/>
              </StackPanel>
            </StackPanel>
          </Border>
          <Border Grid.Row="1" Style="{StaticResource Card}" Padding="4">
            <DataGrid x:Name="gridGroupDiff" Style="{StaticResource ADGrid}"/>
          </Border>
        </Grid>
      </TabItem>

      <!-- TAB: AD HEALTH -->
      <TabItem Header="AD Health" ToolTip="Domain health: DC reachability, LDAP, replication, SYSVOL, NETLOGON, policies">
        <Grid Margin="4">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,6">
            <Button x:Name="btnRunHealth"    Content="Run Health Check" Style="{StaticResource AccentBtn}" Margin="0,0,8,0"/>
            <Button x:Name="btnExportHealth" Content="Export CSV"       Style="{StaticResource GreenBtn}"/>
            <TextBlock x:Name="lblHealthStatus" Text="" VerticalAlignment="Center" FontSize="11" Foreground="#555" Margin="12,0,0,0"/>
          </StackPanel>
          <Border Grid.Row="1" Style="{StaticResource Card}" Padding="4">
            <DataGrid x:Name="gridHealth" Style="{StaticResource ADGrid}"/>
          </Border>
        </Grid>
      </TabItem>

      <!-- TAB: NETWORK STATUS -->
      <TabItem Header="Net Status" ToolTip="Ping all domain computers - live online/offline status with IP, OS, last logon">
        <Grid Margin="4">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="200" MinHeight="100"/>
            <RowDefinition Height="4"/>
            <RowDefinition Height="*" MinHeight="80"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <Border Grid.Row="0" Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Network Status - Domain Computers" Style="{StaticResource SectionHdr}"/>
              <StackPanel Orientation="Horizontal" Margin="0,6,0,0">
                <Button x:Name="btnNetGetComputers" Content="Get Computers" Style="{StaticResource SecBtn}" Margin="0,0,8,0" ToolTip="Load computer list from AD - then choose which to scan"/>
                <Button x:Name="btnNetScan"   Content="Start Scan" Style="{StaticResource AccentBtn}" Margin="0,0,6,0" ToolTip="Scan selected computers (parallel - much faster)"/>
                <Button x:Name="btnNetStop"   Content="Stop"       Style="{StaticResource DangerBtn}" Margin="0,0,10,0" Visibility="Collapsed"/>
                <Button x:Name="btnNetExport" Content="Export CSV" Style="{StaticResource GreenBtn}"  Margin="0,0,16,0"/>
                <TextBlock Text="Timeout (ms):" VerticalAlignment="Center" FontSize="11" Margin="0,0,4,0"/>
                <TextBox x:Name="txtNetTimeout" Style="{StaticResource FBox}" Width="52" Text="30"  Margin="0,0,10,0" ToolTip="Ping timeout ms (default 30)"/>
                <TextBlock Text="Retries:" VerticalAlignment="Center" FontSize="11" Margin="0,0,4,0"/>
                <TextBox x:Name="txtNetRetries" Style="{StaticResource FBox}" Width="36" Text="0" Margin="0,0,10,0" ToolTip="Retry count on failure (0 = no retry)"/>
                <TextBlock Text="Threads:" VerticalAlignment="Center" FontSize="11" Margin="0,0,4,0" ToolTip="Parallel threads - higher = faster scan"/>
                <TextBox x:Name="txtNetThreads" Style="{StaticResource FBox}" Width="36" Text="20" Margin="0,0,16,0" ToolTip="Parallel scan threads (default 20, max 50)"/>
                <TextBlock Text="Discovery:" VerticalAlignment="Center" FontSize="11" Margin="0,0,4,0" ToolTip="Method used to detect if a computer is reachable"/>
                <ComboBox x:Name="cmbNetMethod" Width="180" Height="26" FontSize="11" Margin="0,0,12,0">
                  <ComboBox.ToolTip>
                    <ToolTip MaxWidth="400">
                      <StackPanel>
                        <TextBlock Text="Discovery Method" FontWeight="SemiBold" Margin="0,0,0,4"/>
                        <TextBlock TextWrapping="Wrap" Text="Ping (ICMP): Standard ICMP echo - may be blocked by Windows Firewall on workstations."/>
                        <TextBlock TextWrapping="Wrap" Margin="0,4,0,0" Text="TCP 445 (SMB): Tries SMB port - usually open on domain-joined machines even when ICMP is blocked."/>
                        <TextBlock TextWrapping="Wrap" Margin="0,4,0,0" Text="TCP 88 (Kerberos): Domain controllers and AD machines."/>
                        <TextBlock TextWrapping="Wrap" Margin="0,4,0,0" Text="TCP 389 (LDAP): Domain controllers."/>
                        <TextBlock TextWrapping="Wrap" Margin="0,4,0,0" Text="TCP 3389 (RDP): Workstations with Remote Desktop enabled."/>
                        <TextBlock TextWrapping="Wrap" Margin="0,4,0,0" Foreground="#2E7D32" Text="Multi-port: Tries Ping then 445/88/389/3389 in sequence - finds most machines including those that block ICMP."/>
                      </StackPanel>
                    </ToolTip>
                  </ComboBox.ToolTip>
                  <ComboBoxItem Content="Ping (ICMP)"/>
                  <ComboBoxItem Content="TCP 445 (SMB)"/>
                  <ComboBoxItem Content="TCP 88 (Kerberos)"/>
                  <ComboBoxItem Content="TCP 389 (LDAP)"/>
                  <ComboBoxItem Content="TCP 3389 (RDP)"/>
                  <ComboBoxItem Content="Multi-port (any)" IsSelected="True"/>
                </ComboBox>
                <CheckBox x:Name="chkNetOnlineOnly" Content="Online only" IsChecked="True" VerticalAlignment="Center" FontSize="11" Margin="0,0,14,0"
                          ToolTip="Show only computers that respond. Offline computers are not shown in results."/>
                <CheckBox x:Name="chkNetWMI" Content="WMI" VerticalAlignment="Center" FontSize="11" Margin="0,0,14,0">
                  <CheckBox.ToolTip>
                    <ToolTip MaxWidth="380">
                      <StackPanel>
                        <TextBlock Text="WMI Query (Uptime, RAM, Free Disk)" FontWeight="SemiBold" Margin="0,0,0,4"/>
                        <TextBlock TextWrapping="Wrap" Text="Queries Win32_OperatingSystem and Win32_LogicalDisk via DCOM (port 135 + dynamic ports)."/>
                        <TextBlock TextWrapping="Wrap" Margin="0,4,0,0" Text="REQUIREMENT: Windows Firewall must allow 'Windows Management Instrumentation (WMI)' inbound rules."/>
                        <TextBlock TextWrapping="Wrap" Margin="0,4,0,0" Foreground="#E65100" Text="Works on: Windows Server (enabled by default in domain). Fails on: Windows 10/11 workstations unless firewall rule is enabled."/>
                        <TextBlock TextWrapping="Wrap" Margin="0,6,0,0" Text="GPO fix: Computer Config -> Firewall -> Inbound -> Enable 'Windows Management Instrumentation (WMI-In, DCOM-In, ASync-In)'"/>
                        <TextBlock TextWrapping="Wrap" Margin="0,2,0,0" Foreground="#555" FontStyle="Italic" Text="Or run on each PC: Enable-NetFirewallRule -DisplayGroup 'Windows Management Instrumentation (WMI)'"/>
                      </StackPanel>
                    </ToolTip>
                  </CheckBox.ToolTip>
                </CheckBox>
                <CheckBox x:Name="chkNetPSRemoting" Content="PSRemoting" VerticalAlignment="Center" FontSize="11" Margin="0,0,14,0">
                  <CheckBox.ToolTip>
                    <ToolTip MaxWidth="380">
                      <StackPanel>
                        <TextBlock Text="PSRemoting / WinRM Fallback" FontWeight="SemiBold" Margin="0,0,0,4"/>
                        <TextBlock TextWrapping="Wrap" Text="Uses Invoke-Command over WinRM (port 5985 HTTP / 5986 HTTPS) as fallback when WMI fails. Gets the same data (Uptime, RAM, Disk) but via PowerShell session."/>
                        <TextBlock TextWrapping="Wrap" Margin="0,4,0,0" Text="REQUIREMENT: WinRM service must be running and firewall must allow port 5985."/>
                        <TextBlock TextWrapping="Wrap" Margin="0,4,0,0" Foreground="#2E7D32" Text="Easier to enable than WMI on workstations. Also works through HTTPS (5986) if configured."/>
                        <TextBlock TextWrapping="Wrap" Margin="0,6,0,0" Text="GPO fix: Computer Config -> Windows Settings -> Security Settings -> System Services -> Windows Remote Management -> Automatic"/>
                        <TextBlock TextWrapping="Wrap" Margin="0,2,0,0" Foreground="#555" FontStyle="Italic" Text="Or run on each PC: Enable-PSRemoting -Force"/>
                      </StackPanel>
                    </ToolTip>
                  </CheckBox.ToolTip>
                </CheckBox>
                <CheckBox x:Name="chkNetRemoteReg" Content="RemoteReg (LastUser)" VerticalAlignment="Center" FontSize="11" Margin="0,0,14,0">
                  <CheckBox.ToolTip>
                    <ToolTip MaxWidth="380">
                      <StackPanel>
                        <TextBlock Text="Remote Registry - Last Logged On User" FontWeight="SemiBold" Margin="0,0,0,4"/>
                        <TextBlock TextWrapping="Wrap" Text="Reads HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\LastLoggedOnUser via Remote Registry service."/>
                        <TextBlock TextWrapping="Wrap" Margin="0,4,0,0" Text="Shows the LAST user who logged on (even if currently logged off). More reliable than Win32_ComputerSystem.UserName which shows only the current user."/>
                        <TextBlock TextWrapping="Wrap" Margin="0,4,0,0" Foreground="#E65100" Text="REQUIREMENT: 'Remote Registry' Windows service must be running on target. Stopped by default on Windows 10/11."/>
                        <TextBlock TextWrapping="Wrap" Margin="0,6,0,0" Text="GPO fix: Computer Config -> Windows Settings -> Security Settings -> System Services -> Remote Registry -> Automatic (Started)"/>
                        <TextBlock TextWrapping="Wrap" Margin="0,2,0,0" Foreground="#555" FontStyle="Italic" Text="Or run on each PC: Set-Service RemoteRegistry -StartupType Automatic; Start-Service RemoteRegistry"/>
                      </StackPanel>
                    </ToolTip>
                  </CheckBox.ToolTip>
                </CheckBox>
                <TextBlock x:Name="lblNetProgress" Text="" FontSize="11" Foreground="#555" VerticalAlignment="Center"/>
              </StackPanel>
            </StackPanel>
          </Border>
          <!-- Computer selection panel -->
          <Border Grid.Row="1" Style="{StaticResource Card}" Padding="6" x:Name="borderNetComputers" Visibility="Collapsed">
            <DockPanel>
              <DockPanel DockPanel.Dock="Top" Margin="0,0,0,6">
                <TextBlock x:Name="lblNetCompCount" Text="Computers loaded from AD:" FontSize="11" Foreground="#555" DockPanel.Dock="Left" VerticalAlignment="Center"/>
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" DockPanel.Dock="Right">
                  <Button x:Name="btnNetSelectAll"  Content="Select All"  Style="{StaticResource SecBtn}" Margin="0,0,6,0" Height="24" FontSize="11"/>
                  <Button x:Name="btnNetSelectNone" Content="Clear"       Style="{StaticResource SecBtn}" Height="24" FontSize="11"/>
                </StackPanel>
              </DockPanel>
              <Border BorderBrush="#DDE1E7" BorderThickness="1" CornerRadius="4">
                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" CanContentScroll="False">
                  <StackPanel x:Name="lstNetComputers" HorizontalAlignment="Left"/>
                </ScrollViewer>
              </Border>
            </DockPanel>
          </Border>
          <GridSplitter Grid.Row="2" Height="4" HorizontalAlignment="Stretch" VerticalAlignment="Center"
                        Background="#CCD3DC" ShowsPreview="True" ResizeBehavior="PreviousAndNext"
                        ToolTip="Drag to resize panels"/>
          <Border Grid.Row="3" Style="{StaticResource Card}" Padding="4">
            <DataGrid x:Name="gridNetStatus" Style="{StaticResource ADGrid}" IsReadOnly="True">
              <DataGrid.ContextMenu>
                <ContextMenu>
                  <MenuItem x:Name="ctxNetCopyCell" Header="Copy cell value"/>
                  <MenuItem x:Name="ctxNetCopyRow"  Header="Copy row (tab-sep)"/>
                  <Separator/>
                  <MenuItem x:Name="ctxNetPing" Header="Ping (continuous)..."/>
                  <MenuItem x:Name="ctxNetRDP"  Header="RDP connect..."/>
                </ContextMenu>
              </DataGrid.ContextMenu>
            </DataGrid>
          </Border>
          <TextBlock Grid.Row="4" x:Name="lblNetCount" Text="" FontSize="11" Foreground="#777" Margin="2,2,0,0"/>
        </Grid>
      </TabItem>

      <!-- TAB 14: OUTPUT -->
      <TabItem Header="Output"  ToolTip="Live command output - every PS cmdlet executed with results">
        <Grid Margin="4">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,6">
            <Button x:Name="btnClearOutput"   Content="Clear"      Style="{StaticResource SecBtn}" Margin="0,0,8,0"/>
            <Button x:Name="btnSaveOutputBtn" Content="Save..."    Style="{StaticResource SecBtn}" Margin="0,0,8,0"/>
            <CheckBox x:Name="chkAutoScroll"  Content="Auto-scroll" IsChecked="True" VerticalAlignment="Center" FontSize="11"/>
          </StackPanel>
          <Border Grid.Row="1" Style="{StaticResource Card}" Padding="4">
            <TextBox x:Name="txtOutput" IsReadOnly="True" FontFamily="Consolas" FontSize="11"
                     TextWrapping="NoWrap" AcceptsReturn="True"
                     VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                     Background="#0C0C0C" Foreground="#00FF7F"/>
          </Border>
        </Grid>
      </TabItem>

      <!-- TAB 15: LOG -->
      <TabItem Header="Log"     ToolTip="Timestamped event log for this session">
        <Grid Margin="4">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,6">
            <Button x:Name="btnClearLog"   Content="Clear"    Style="{StaticResource SecBtn}" Margin="0,0,8,0"/>
            <Button x:Name="btnSaveLogBtn" Content="Save log" Style="{StaticResource SecBtn}"/>
          </StackPanel>
          <Border Grid.Row="1" Style="{StaticResource Card}" Padding="4">
            <TextBox x:Name="txtLog" IsReadOnly="True" FontFamily="Consolas" FontSize="11"
                     TextWrapping="NoWrap" AcceptsReturn="True"
                     VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                     Background="#1E1E1E" Foreground="#D4D4D4"/>
          </Border>
        </Grid>
      </TabItem>

    </TabControl>
  </DockPanel>
</Window>
"@
#endregion

#region ── Load Window ────────────────────────────────────────────────────────
try {
    $reader = [System.Xml.XmlNodeReader]::new($XAML)
    $Window = [Windows.Markup.XamlReader]::Load($reader)
} catch {
    [System.Windows.Forms.MessageBox]::Show("XAML load error:`n$($_.Exception.Message)","AD Manager - Fatal","OK","Error")
    exit 1
}

function B { param([string]$n) $Window.FindName($n) }

$Global:pbMain    = B "pbMain"
$Global:lblStatus = B "lblStatus"
$Global:lblDomain = B "lblDomain"
$Global:txtLog    = B "txtLog"
$Global:txtOutput = B "txtOutput"
$Global:chkAutoScroll = B "chkAutoScroll"

# System tab
$lblOS = B "lblOS"; $lblOSBuild = B "lblOSBuild"; $lblOSArch = B "lblOSArch"; $lblInstallDate = B "lblInstallDate"
$lblHostname = B "lblHostname"; $lblLastBoot = B "lblLastBoot"; $lblTimeZone = B "lblTimeZone"; $lblUptime = B "lblUptime"
$lblRegUser = B "lblRegUser"; $lblDomain2 = B "lblDomain2"
$lblMfg = B "lblMfg"; $lblModel = B "lblModel"; $lblSerial = B "lblSerial"; $lblSystemType = B "lblSystemType"
$lblBiosMfg = B "lblBiosMfg"; $lblBiosVer = B "lblBiosVer"; $lblBiosSN = B "lblBiosSN"; $lblBiosDate = B "lblBiosDate"
$gridRamSticks = B "gridRamSticks"; $gridPhysDisk = B "gridPhysDisk"; $gridNetAdapters = B "gridNetAdapters"
$gridServices = B "gridServices"; $gridStartup = B "gridStartup"; $gridProcs = B "gridProcs"
$txtSvcFilter = B "txtSvcFilter"
$lblRamTotal = B "lblRamTotal"; $lblRamAvail = B "lblRamAvail"; $lblRamUsed = B "lblRamUsed"; $lblRamPct = B "lblRamPct"
$pbRam = B "pbRam"; $gridDisk = B "gridDisk"; $btnRefreshSystem = B "btnRefreshSystem"
$lblCpu = B "lblCpu"; $lblCpuCores = B "lblCpuCores"; $lblCpuSpeed = B "lblCpuSpeed"; $lblCpuLoad = B "lblCpuLoad"

# Domain tab
$lblDomainName = B "lblDomainName"; $lblDomainDNS = B "lblDomainDNS"; $lblDomainNetbios = B "lblDomainNetbios"
$lblDomainMode = B "lblDomainMode"; $lblForestName = B "lblForestName"; $lblForestMode = B "lblForestMode"
$lblDomainSID = B "lblDomainSID"; $lblSites = B "lblSites"; $lblUsersCount = B "lblUsersCount"; $lblGroupsCount = B "lblGroupsCount"
$lblPDC = B "lblPDC"; $lblRID = B "lblRID"; $lblInfra = B "lblInfra"; $lblSchema = B "lblSchema"; $lblDNM = B "lblDNM"
$gridDCs = B "gridDCs"; $btnRefreshDomain = B "btnRefreshDomain"

# OU tab
$treeOU = B "treeOU"; $btnLoadOUs = B "btnLoadOUs"; $btnExportOUsBtn = B "btnExportOUsBtn"
$txtOUFilter = B "txtOUFilter"; $lblOUCount = B "lblOUCount"

# Shares tab
$gridShares = B "gridShares"; $gridPerms = B "gridPerms"
$btnLoadShares = B "btnLoadShares"; $btnExportSharesBtn = B "btnExportSharesBtn"
$btnExportPermsBtn = B "btnExportPermsBtn"; $txtCheckUser = B "txtCheckUser"
$txtScanDepth = B "txtScanDepth"
$btnPickUsers = B "btnPickUsers"
$btnPickGroups = B "btnPickGroups"
$btnBrowseFolder = B "btnBrowseFolder"; $btnCheckPerms = B "btnCheckPerms"
$btnStopScan = B "btnStopScan"
$lblScanProgress = B "lblScanProgress"
$btnExportPermsResult = B "btnExportPermsResult"
$chkSkipSystemFolders = B "chkSkipSystemFolders"
$chkSkipAdminShares   = B "chkSkipAdminShares"
$chkLimitResults      = B "chkLimitResults"
$Script:ScanCancelFlag = $false
$Script:ScanCancel = [hashtable]::Synchronized(@{Value=$false})

# Users tab
$gridUsers = B "gridUsers"; $btnLoadUsers = B "btnLoadUsers"; $btnExportUsersBtn = B "btnExportUsersBtn"
$btnUserAudit = B "btnUserAudit"
$btnExportUsersXlsx = B "btnExportUsersXlsx"
$txtUserFilter = B "txtUserFilter"; $txtUserLiveFilter = B "txtUserLiveFilter"; $chkDisabledUsers = B "chkDisabledUsers"
$btnEnableSelected = B "btnEnableSelected"; $btnDisableSelected = B "btnDisableSelected"
$btnMemberOf = B "btnMemberOf"; $gridMemberOf = B "gridMemberOf"
$lblMemberOfTitle = B "lblMemberOfTitle"; $panelMemberOf = B "panelMemberOf"
$btnShowHeatmap = B "btnShowHeatmap"; $panelUsersHeatmap = B "panelUsersHeatmap"
$icUsersHeatmap = B "icUsersHeatmap"; $lblUsersHeatmapInfo = B "lblUsersHeatmapInfo"
$lblUsersRowCount = B "lblUsersRowCount"
$borderHeatmapDetail = B "borderHeatmapDetail"; $gridHeatmapDetail = B "gridHeatmapDetail"
$borderUsersHeatmapDetail = B "borderUsersHeatmapDetail"; $gridUsersHeatmapDetail = B "gridUsersHeatmapDetail"
$lblUsersHeatmapDetailTitle = B "lblUsersHeatmapDetailTitle"; $btnUsersHeatmapDetailClose = B "btnUsersHeatmapDetailClose"
$lblHeatmapDetailTitle = B "lblHeatmapDetailTitle"; $btnHeatmapDetailClose = B "btnHeatmapDetailClose"
$ctxCopyCell = B "ctxCopyCell"; $ctxCopyRow = B "ctxCopyRow"; $ctxUserDetail = B "ctxUserDetail"
$ctxOUCopy = B "ctxOUCopy"; $ctxOULoadUsers = B "ctxOULoadUsers"
$lblGroupsRowCount = B "lblGroupsRowCount"
$menuSettings = B "menuSettings"; $menuExportExcel = B "menuExportExcel"
$Script:LiveFilterEnabled = $true
$Script:UserCV = $null  # CollectionView for live filter
# New feature controls
$btnResetPassword  = B "btnResetPassword";  $btnUnlockAccount  = B "btnUnlockAccount"
$btnLoadHeatmap    = B "btnLoadHeatmap";    $icHeatmap         = B "icHeatmap"
$lblHeatmapInfo    = B "lblHeatmapInfo"
$txtStaleDays      = B "txtStaleDays";      $btnLoadStale      = B "btnLoadStale"
$btnNetScan = B "btnNetScan"; $btnNetStop = B "btnNetStop"; $btnNetExport = B "btnNetExport"
$btnNetGetComputers = B "btnNetGetComputers"
$cmbNetMethod = B "cmbNetMethod"
$btnNetSelectAll = B "btnNetSelectAll"; $btnNetSelectNone = B "btnNetSelectNone"
$borderNetComputers = B "borderNetComputers"; $lstNetComputers = B "lstNetComputers"
$lblNetCompCount = B "lblNetCompCount"
$txtNetTimeout = B "txtNetTimeout"; $txtNetRetries = B "txtNetRetries"; $txtNetThreads = B "txtNetThreads"
$chkNetOnlineOnly = B "chkNetOnlineOnly"; $chkNetWMI = B "chkNetWMI"
$chkNetPSRemoting = B "chkNetPSRemoting"; $chkNetRemoteReg = B "chkNetRemoteReg"
$lblNetProgress = B "lblNetProgress"; $lblNetCount = B "lblNetCount"
$gridNetStatus = B "gridNetStatus"
$ctxNetCopyCell = B "ctxNetCopyCell"; $ctxNetCopyRow = B "ctxNetCopyRow"
$ctxNetPing = B "ctxNetPing"; $ctxNetRDP = B "ctxNetRDP"
$Script:NetScanCancel = $false
$btnExportStale    = B "btnExportStale";    $gridStale         = B "gridStale"
$txtDiffUserA      = B "txtDiffUserA";      $txtDiffUserB      = B "txtDiffUserB"
$btnPickDiffA      = B "btnPickDiffA";      $btnPickDiffB      = B "btnPickDiffB"
$btnRunDiff        = B "btnRunDiff";        $btnExportDiff     = B "btnExportDiff"
$gridGroupDiff     = B "gridGroupDiff"
$btnRunHealth      = B "btnRunHealth";      $btnExportHealth   = B "btnExportHealth"
$gridHealth        = B "gridHealth";        $lblHealthStatus   = B "lblHealthStatus"
$btnDarkMode       = B "btnDarkMode"
$Script:CachedStale     = $null
$Script:HeatmapBucketUsers = @{}
$Script:CachedGroupDiff = $null
$Script:CachedHealth    = $null
$Script:IsDarkMode      = $false
$panelMemberOf = B "panelMemberOf"; $lblMemberOfTitle = B "lblMemberOfTitle"

# Groups tab
$gridGroups = B "gridGroups"; $btnLoadGroups = B "btnLoadGroups"; $btnExportGroupsBtn = B "btnExportGroupsBtn"
$ctxGroupDetails = B "ctxGroupDetails"
$txtGroupFilter = B "txtGroupFilter"; $chkNestedMembers = B "chkNestedMembers"

# Computers tab
$gridComputers = B "gridComputers"; $btnLoadComputers = B "btnLoadComputers"
$btnComputerHeatmap = B "btnComputerHeatmap"; $panelComputerHeatmap = B "panelComputerHeatmap"
$icComputerHeatmap = B "icComputerHeatmap"; $lblComputerHeatmapInfo = B "lblComputerHeatmapInfo"
$borderComputerHeatmapDetail = B "borderComputerHeatmapDetail"; $gridComputerHeatmapDetail = B "gridComputerHeatmapDetail"
$lblComputerHeatmapDetailTitle = B "lblComputerHeatmapDetailTitle"; $btnComputerHeatmapDetailClose = B "btnComputerHeatmapDetailClose"
$lblComputersRowCount = B "lblComputersRowCount"
$btnExportComputersBtn = B "btnExportComputersBtn"; $txtComputerFilter = B "txtComputerFilter"

# GPOs tab
$gridGPOs = B "gridGPOs"; $btnLoadGPOs = B "btnLoadGPOs"; $btnExportGPOsBtn = B "btnExportGPOsBtn"
$btnLoadGPOLinks = B "btnLoadGPOLinks"; $gridGPOLinks = B "gridGPOLinks"

# Pwd Expiry tab
$gridPwdExpiry = B "gridPwdExpiry"; $txtPwdDays = B "txtPwdDays"
$btnPwdExpiry = B "btnPwdExpiry"; $btnExportPwdExpiry = B "btnExportPwdExpiry"

# Inactive tab
$gridInactiveUsers = B "gridInactiveUsers"; $gridInactiveComp = B "gridInactiveComp"
$txtInactiveDays = B "txtInactiveDays"; $btnLoadInactive = B "btnLoadInactive"
$btnLoadInactiveComp = B "btnLoadInactiveComp"; $btnExportInactive = B "btnExportInactive"

# Recycle Bin tab
$gridRecycleBin = B "gridRecycleBin"; $btnLoadRecycleBin = B "btnLoadRecycleBin"
$btnExportRecycleBin = B "btnExportRecycleBin"

# DNS tab
$gridDNSZones = B "gridDNSZones"; $gridDNSRecords = B "gridDNSRecords"
$btnLoadDNS = B "btnLoadDNS"; $btnExportDNS = B "btnExportDNS"; $btnLoadDNSRec = B "btnLoadDNSRec"

# DHCP tab
$gridDHCP = B "gridDHCP"; $gridLeases = B "gridLeases"; $txtDhcpServer = B "txtDhcpServer"
$btnLoadDHCP = B "btnLoadDHCP"; $btnExportDHCP = B "btnExportDHCP"; $btnLoadLeases = B "btnLoadLeases"

# Log tab
$btnClearLog = B "btnClearLog"; $btnSaveLogBtn = B "btnSaveLogBtn"
$btnClearOutput = B "btnClearOutput"; $btnSaveOutputBtn = B "btnSaveOutputBtn"

# Menu
$menuRefreshAll = B "menuRefreshAll"; $menuSaveLog = B "menuSaveLog"; $menuExit = B "menuExit"
$menuExportUsers = B "menuExportUsers"; $menuExportGroups = B "menuExportGroups"
$menuExportComputers = B "menuExportComputers"; $menuExportOUs = B "menuExportOUs"
$menuExportGPOs = B "menuExportGPOs"; $menuExportShares = B "menuExportShares"
$menuExportPerms = B "menuExportPerms"; $menuModules = B "menuModules"
$menuClearLog = B "menuClearLog"; $menuAbout = B "menuAbout"
#endregion


#region ── Background Runner (Runspace-based, non-blocking UI) ──────────────
$Script:ActiveJobs = [System.Collections.Generic.List[hashtable]]::new()

function Invoke-Background {
    param(
        [string]$JobName,
        [scriptblock]$ScriptBlock,
        [hashtable]$Variables = @{},
        [System.Windows.Controls.Button[]]$DisableButtons = @()
    )

    # Disable buttons during run
    foreach ($b in $DisableButtons) {
        try { $b.Dispatcher.Invoke([action]{ $b.IsEnabled = $false }) } catch { }
    }
    Write-Out "--- START: $JobName ---" "SEP"

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = "STA"
    $rs.ThreadOptions  = "ReuseThread"
    $rs.Open()

    # Pass shared variables into the runspace
    $rs.SessionStateProxy.SetVariable("Global_txtOutput",   $Global:txtOutput)
    $rs.SessionStateProxy.SetVariable("Global_txtLog",      $Global:txtLog)
    $rs.SessionStateProxy.SetVariable("Global_pbMain",      $Global:pbMain)
    $rs.SessionStateProxy.SetVariable("Global_lblStatus",   $Global:lblStatus)
    $rs.SessionStateProxy.SetVariable("Global_chkAutoScroll",$Global:chkAutoScroll)
    $rs.SessionStateProxy.SetVariable("Script_LogBuffer",   $Script:LogBuffer)
    $rs.SessionStateProxy.SetVariable("Script_OutputBuffer",$Script:OutputBuffer)

    foreach ($kv in $Variables.GetEnumerator()) {
        $rs.SessionStateProxy.SetVariable($kv.Key, $kv.Value)
    }

    # Inject Write-Out + Write-ADLog + Set-Status into the runspace
    $initScript = {
        function Write-Out {
            param([string]$Text, [string]$Kind = "INFO")
            $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            $logLine = "[$ts][$Kind] $Text"
            $outLine = switch ($Kind) {
                "CMD"    { "`n[$ts] PS> $Text" }
                "RESULT" { "    $Text" }
                "ERROR"  { "[$ts][ERR] $Text" }
                "WARN"   { "[$ts][WRN] $Text" }
                "OK"     { "[$ts][ OK] $Text" }
                "SEP"    { "`n---- $Text ----" }
                default  { "[$ts][INF] $Text" }
            }
            [void]$Script_LogBuffer.AppendLine($logLine)
            [void]$Script_OutputBuffer.AppendLine($logLine)
            try {
                $Global_txtLog.Dispatcher.Invoke([action]{ $Global_txtLog.AppendText($logLine + "`n"); $Global_txtLog.ScrollToEnd() })
            } catch { }
            try {
                $Global_txtOutput.Dispatcher.Invoke([action]{
                    $Global_txtOutput.AppendText($outLine + "`n")
                    if ($Global_chkAutoScroll.IsChecked) { $Global_txtOutput.ScrollToEnd() }
                })
            } catch { }
        }
        function Write-ADLog { param([string]$Msg, [string]$Level="INFO") Write-Out -Text $Msg -Kind $Level }
        function Write-OutputCmd    { param([string]$Cmd)  Write-Out $Cmd  "CMD"    }
        function Write-OutputResult { param([string]$Text) Write-Out $Text "RESULT" }
        function Set-Status {
            param([string]$Msg, [int]$Pct = -1)
            try { $Global_lblStatus.Dispatcher.Invoke([action]{ $Global_lblStatus.Text = $Msg }) } catch { }
            try { if ($Pct -ge 0) { $Global_pbMain.Dispatcher.Invoke([action]{ $Global_pbMain.Value = $Pct }) } } catch { }
            Write-Out $Msg "INFO"
        }
        function Show-Info { param([string]$Msg) [System.Windows.MessageBox]::Show($Msg,"AD Manager","OK","Information") | Out-Null }
        function Show-Err  { param([string]$Msg) [System.Windows.MessageBox]::Show($Msg,"Error","OK","Error") | Out-Null }
        function Ensure-ADModule {
            if (Get-Module -Name ActiveDirectory -EA SilentlyContinue) { return $true }
            try { Import-Module ActiveDirectory -EA Stop; return $true }
            catch { Show-Err "ActiveDirectory module not found."; return $false }
        }
        function Ensure-GPModule {
            if (Get-Module -Name GroupPolicy -EA SilentlyContinue) { return $true }
            try { Import-Module GroupPolicy -EA Stop; return $true }
            catch { Show-Err "GroupPolicy module not found."; return $false }
        }
        function Ensure-DnsModule {
            if (Get-Module -Name DnsServer -EA SilentlyContinue) { return $true }
            try { Import-Module DnsServer -EA Stop; return $true }
            catch { Show-Err "DnsServer module not found."; return $false }
        }
        function Ensure-DhcpModule {
            if (Get-Module -Name DhcpServer -EA SilentlyContinue) { return $true }
            try { Import-Module DhcpServer -EA Stop; return $true }
            catch { Show-Err "DhcpServer module not found."; return $false }
        }
        function Export-ToCSV {
            param($Data, [string]$DefaultName)
            if (-not $Data) { Show-Err "No data to export."; return }
            $dlg = New-Object System.Windows.Forms.SaveFileDialog
            $dlg.Filter = "CSV files (*.csv)|*.csv"; $dlg.FileName = $DefaultName
            if ($dlg.ShowDialog() -eq "OK") {
                try { $Data | Export-Csv -Path $dlg.FileName -NoTypeInformation -Encoding UTF8; Show-Info "Exported to: $($dlg.FileName)" }
                catch { Show-Err $_.Exception.Message }
            }
        }
        function Get-NTFSPermissionsRecursive {
            param([string]$Path, [string]$Identity, [string]$ShareName, [int]$MaxDepth = 2)
            $results = [System.Collections.Generic.List[object]]::new()
            $queue   = [System.Collections.Queue]::new()
            $queue.Enqueue(@{P=$Path; D=0})
            while ($queue.Count -gt 0) {
                $item = $queue.Dequeue(); $fpath = $item.P; $depth = $item.D
                Write-Out "  Get-Acl '$fpath'" "CMD"
                try {
                    $acl = Get-Acl -Path $fpath -EA Stop
                    foreach ($ace in $acl.Access) {
                        $id = $ace.IdentityReference.Value; $uname = ($id -split "\\")[-1]
                        if ($uname -ieq $Identity -or $id -ieq $Identity) {
                            $r = [PSCustomObject]@{ShareName=$ShareName;FolderPath=$fpath;Principal=$id;AccessType=$ace.AccessControlType.ToString();Rights=$ace.FileSystemRights.ToString();Inherited=$ace.IsInherited;Source="NTFS"}
                            $results.Add($r)
                            Write-Out "    MATCH: $id | $($ace.AccessControlType) | $($ace.FileSystemRights)" "RESULT"
                        }
                    }
                } catch { Write-Out "  ERROR reading ACL: $fpath - $($_.Exception.Message)" "ERROR" }
                if ($depth -lt $MaxDepth) {
                    try { Get-ChildItem -Path $fpath -Directory -EA SilentlyContinue | ForEach-Object { $queue.Enqueue(@{P=$_.FullName; D=($depth+1)}) } } catch { }
                }
            }
            return $results
        }
        Add-Type -AssemblyName System.Windows.Forms -EA SilentlyContinue
    }

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($initScript)
    [void]$ps.AddScript($ScriptBlock)
    $handle = $ps.BeginInvoke()

    $job = @{ Name=$JobName; PS=$ps; RS=$rs; Handle=$handle; Buttons=$DisableButtons; StartTime=(Get-Date) }
    [void]$Script:ActiveJobs.Add($job)

    # Timer to poll completion
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(300)
    $timer.Add_Tick({
        $done = $job.Handle.IsCompleted
        if ($done) {
            $timer.Stop()
            try {
                $errs = $job.PS.Streams.Error
                foreach ($e in $errs) { Write-Out "RUNSPACE ERROR: $e" "ERROR" }
                $job.PS.EndInvoke($job.Handle)
            } catch { Write-Out "Job end error: $($_.Exception.Message)" "ERROR" }
            $job.PS.Dispose()
            $job.RS.Dispose()
            $elapsed = [math]::Round(((Get-Date) - $job.StartTime).TotalSeconds, 1)
            Write-Out "--- DONE: $($job.Name) (${elapsed}s) ---" "SEP"
            Set-Status "Done: $($job.Name)." 100
            foreach ($b in $job.Buttons) {
                try { $b.Dispatcher.Invoke([action]{ $b.IsEnabled = $true }) } catch { }
            }
        }
    })
    $timer.Start()
}
#endregion

#region ── DATA LOADERS ───────────────────────────────────────────────────────

function Load-SystemInfo {
    try {
        Set-Status "Loading OS info..." 10
        Write-Out "Get-CimInstance Win32_OperatingSystem" "CMD"
        $os = $null
        try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch { }
        if (-not $os) { try { $os = Get-WmiObject Win32_OperatingSystem -ErrorAction Stop } catch { } }
        if (-not $os) { Set-Status "Error: cannot read OS info." 0; return }
        $lblOS.Text          = "OS: $($os.Caption)"
        $lblOSBuild.Text     = "Build: $($os.BuildNumber)"
        $lblOSArch.Text      = "Architecture: $($os.OSArchitecture)"
        $lblHostname.Text    = "Hostname: $env:COMPUTERNAME"
        $lblRegUser.Text     = "Registered: $($os.RegisteredUser)"
        $lblDomain2.Text     = "Domain: $env:USERDOMAIN"
        try { $idate = $os.InstallDate; if ($idate -is [string]) { $idate = [Management.ManagementDateTimeConverter]::ToDateTime($idate) }; $lblInstallDate.Text = "Install date: $($idate.ToString('yyyy-MM-dd'))" } catch { $lblInstallDate.Text = 'Install date: ?' }
        try { $lb = $os.LastBootUpTime; if ($lb -is [string]) { $lb = [Management.ManagementDateTimeConverter]::ToDateTime($lb) } } catch { $lb = $null }
        if ($lb) {
            $lblLastBoot.Text = "Last boot: $($lb.ToString('yyyy-MM-dd HH:mm'))"
            $up = (Get-Date) - $lb; $d=$up.Days; $h=$up.Hours; $m=$up.Minutes
            $lblUptime.Text = "Uptime: ${d}d ${h}h ${m}m"
        } else { $lblLastBoot.Text = "Last boot: ?"; $lblUptime.Text = "Uptime: ?" }
        $lblTimeZone.Text    = "Time zone: $([System.TimeZoneInfo]::Local.DisplayName)"

        Set-Status "Loading computer/BIOS info..." 20
        Write-Out "Get-CimInstance Win32_ComputerSystem; Win32_BIOS" "CMD"
        try {
            $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
            $lblMfg.Text        = "Manufacturer: $($cs.Manufacturer)"
            $lblModel.Text      = "Model: $($cs.Model)"
            $lblSystemType.Text = "Type: $($cs.SystemType)"
        } catch {}
        try {
            $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
            $lblBiosMfg.Text  = "BIOS Mfg: $($bios.Manufacturer)"
            $lblBiosVer.Text  = "BIOS Ver: $($bios.SMBIOSBIOSVersion)"
            $lblBiosSN.Text   = "Serial No: $($bios.SerialNumber.Trim())"
            $lblBiosDate.Text = "BIOS Date: $($bios.ReleaseDate)"
            $lblSerial.Text   = "Serial No: $($bios.SerialNumber.Trim())"
        } catch {}

        Set-Status "Loading RAM..." 35
        Write-Out "Get-CimInstance Win32_OperatingSystem  # reading TotalVisibleMemorySize, FreePhysicalMemory" "CMD"
        $rt = [math]::Round([long]$os.TotalVisibleMemorySize / 1MB, 2)
        $rf = [math]::Round([long]$os.FreePhysicalMemory / 1MB, 2)
        $ru = [math]::Round($rt - $rf, 2)
        $rp = if ($rt -gt 0) { [math]::Round(($ru / $rt) * 100, 1) } else { 0 }
        $lblRamTotal.Text = "Total: ${rt} GB"
        $lblRamAvail.Text = "Available: ${rf} GB"
        $lblRamUsed.Text  = "Used: ${ru} GB"
        $lblRamPct.Text   = "Usage: ${rp}%"
        $pbRam.Value = $rp
        try {
            Write-Out "Get-CimInstance Win32_PhysicalMemory" "CMD"
            $sticks = Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop | ForEach-Object {
                [PSCustomObject]@{Slot=$_.DeviceLocator; "Size MB"=[math]::Round($_.Capacity/1MB,0); Speed="$($_.Speed) MHz"; Part=$_.PartNumber.Trim(); Manufacturer=$_.Manufacturer}
            }
            $gridRamSticks.ItemsSource = [object[]]@($sticks)
        } catch {}

        Set-Status "Loading disks..." 55
        Write-Out 'Get-CimInstance Win32_LogicalDisk -Filter DriveType=3' 'CMD'
        $diskObjs = $null
        try { $diskObjs = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop } catch { }
        if (-not $diskObjs) { try { $diskObjs = Get-WmiObject Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop } catch { } }
        $disks = @()
        if ($diskObjs) {
            $disks = $diskObjs | ForEach-Object {
                $t = [math]::Round($_.Size / 1GB, 1); $f = [math]::Round($_.FreeSpace / 1GB, 1)
                $u = [math]::Round($t - $f, 1); $p = if ($t -gt 0) { [math]::Round(($u/$t)*100,1) } else { 0 }
                [PSCustomObject]@{ Drive=$_.DeviceID; Label=$_.VolumeName; "Total GB"=$t; "Used GB"=$u; "Free GB"=$f; "Used%"="${p}%"; FS=$_.FileSystem }
            }
        }
        $gridDisk.ItemsSource = [object[]]@($disks)
        try {
            Write-Out "Get-CimInstance Win32_DiskDrive" "CMD"
            $phys = Get-CimInstance Win32_DiskDrive -ErrorAction Stop | ForEach-Object {
                [PSCustomObject]@{Model=$_.Model; "Size GB"=[math]::Round($_.Size/1GB,1); Interface=$_.InterfaceType; Serial=$_.SerialNumber.Trim(); Partitions=$_.Partitions}
            }
            $gridPhysDisk.ItemsSource = [object[]]@($phys)
        } catch {}

        Set-Status "Loading CPU..." 70
        Write-Out "Get-CimInstance Win32_Processor" "CMD"
        $cpuObj = $null
        try { $cpuObj = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1 } catch { }
        if (-not $cpuObj) { try { $cpuObj = Get-WmiObject Win32_Processor -ErrorAction Stop | Select-Object -First 1 } catch { } }
        if ($cpuObj) {
            $lblCpu.Text      = "CPU: $($cpuObj.Name.Trim())"
            $lblCpuCores.Text = "Cores/Threads: $($cpuObj.NumberOfCores) / $($cpuObj.NumberOfLogicalProcessors)"
            $spd = [math]::Round($cpuObj.MaxClockSpeed / 1000, 2)
            $lblCpuSpeed.Text = "Max Speed: ${spd} GHz"
            $load = $cpuObj.LoadPercentage
            if (-not $load) { try { $allC = Get-CimInstance Win32_Processor -EA Stop } catch { $allC = Get-WmiObject Win32_Processor -EA SilentlyContinue }; $load = if ($allC) { [math]::Round(($allC.LoadPercentage | Measure-Object -Average).Average,1) } else { "?" } }
            $lblCpuLoad.Text  = "Current Load: ${load}%"
        } else { $lblCpu.Text="CPU: (unavailable)"; $lblCpuCores.Text="Cores: ?"; $lblCpuSpeed.Text="Speed: ?"; $lblCpuLoad.Text="Load: ?" }

        Set-Status "Loading network adapters..." 85
        Write-Out "Get-CimInstance Win32_NetworkAdapterConfiguration -Filter IPEnabled=True" "CMD"
        try {
            $nics = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" -ErrorAction Stop | ForEach-Object {
                [PSCustomObject]@{Adapter=$_.Description; MAC=$_.MACAddress; IP=($_.IPAddress -join ", "); Gateway=($_.DefaultIPGateway -join ", "); DNS=($_.DNSServerSearchOrder -join ", ")}
            }
            $gridNetAdapters.ItemsSource = [object[]]@($nics)
        } catch {}

        Set-Status "Loading services..." 88
        try {
            Write-Out "Get-CimInstance Win32_Service" "CMD"
            $svcs = Get-CimInstance Win32_Service -ErrorAction Stop | Sort-Object State, Name | ForEach-Object {
                [PSCustomObject]@{Name=$_.Name; DisplayName=$_.DisplayName; State=$_.State; StartMode=$_.StartMode; Account=$_.StartName}
            }
            $gridServices.ItemsSource = [object[]]@($svcs)
            # Live filter
            $Script:AllServices = $svcs
            $txtSvcFilter.Add_TextChanged({
                $ft = $txtSvcFilter.Text.Trim()
                $gridServices.ItemsSource = if ($ft) {
                    [object[]]@($Script:AllServices | Where-Object { $_.Name -like "*$ft*" -or $_.DisplayName -like "*$ft*" })
                } else { [object[]]@($Script:AllServices) }
            })
        } catch {}

        Set-Status "Loading startup apps..." 92
        try {
            Write-Out "Get-CimInstance Win32_StartupCommand" "CMD"
            $su = Get-CimInstance Win32_StartupCommand -ErrorAction Stop | ForEach-Object {
                [PSCustomObject]@{Name=$_.Name; Command=$_.Command; Location=$_.Location; User=$_.User}
            }
            $gridStartup.ItemsSource = [object[]]@($su)
        } catch {}

        Set-Status "Loading processes..." 95
        try {
            Write-Out "Get-Process | Sort CPU -Desc | Top 30" "CMD"
            $procs = Get-Process -ErrorAction Stop | Sort-Object CPU -Descending | Select-Object -First 30 | ForEach-Object {
                [PSCustomObject]@{Name=$_.Name; PID=$_.Id; "CPU s"=[math]::Round($_.CPU,1); "RAM MB"=[math]::Round($_.WorkingSet/1MB,1); Company=$_.Company}
            }
            $gridProcs.ItemsSource = [object[]]@($procs)
        } catch {}

        Set-Status "System info loaded." 100
    } catch { Set-Status "Error loading system info." 0; Write-ADLog "ERROR Load-SystemInfo: $($_.Exception.Message)" "ERROR" }
}

function Load-DomainInfo {
    if (-not (Ensure-ADModule)) { return }
    try {
        Set-Status "Loading domain..." 10
    Write-Out "Get-ADDomain ; Get-ADForest" "CMD"
        $dom = Get-ADDomain; $fst = Get-ADForest
        $lblDomainName.Text    = "Name: $($dom.Name)"
        $lblDomainDNS.Text     = "DNS Root: $($dom.DNSRoot)"
        $lblDomainNetbios.Text = "NetBIOS: $($dom.NetBIOSName)"
        $lblDomainMode.Text    = "Functional level: $($dom.DomainMode)"
        $lblForestName.Text    = "Forest: $($fst.Name)"
        $lblForestMode.Text    = "Forest level: $($fst.ForestMode)"
        $lblDomainSID.Text     = "Domain SID: $($dom.DomainSID.Value)"
        $sites = ($fst.Sites | Sort-Object) -join ", "
        $lblSites.Text = "Sites: $(if($sites){$sites}else{'(none)'})"
        Set-Status "Counting objects..." 40
    Write-Out "(Get-ADUser -Filter *).Count ; (Get-ADGroup -Filter *).Count" "CMD"
        $uC = (Get-ADUser  -Filter *).Count
        $gC = (Get-ADGroup -Filter *).Count
        $lblUsersCount.Text  = "Users: $uC"
        $lblGroupsCount.Text = "Groups: $gC"
        Set-Status "Loading FSMO..." 65
    Write-Out "Get-ADDomain | Select PDCEmulator,RIDMaster,InfrastructureMaster ; Get-ADForest | Select SchemaMaster,DomainNamingMaster" "CMD"
        $lblPDC.Text    = $dom.PDCEmulator
        $lblRID.Text    = $dom.RIDMaster
        $lblInfra.Text  = $dom.InfrastructureMaster
        $lblSchema.Text = $fst.SchemaMaster
        $lblDNM.Text    = $fst.DomainNamingMaster
        Set-Status "Loading DCs..." 85
    Write-Out "Get-ADDomainController -Filter * | Select Name,IPv4Address,OperatingSystem,Site,IsGlobalCatalog,IsReadOnly" "CMD"
        $dcs = Get-ADDomainController -Filter * | Select-Object Name, IPv4Address, OperatingSystem, Site, IsGlobalCatalog, IsReadOnly
        $gridDCs.ItemsSource = [object[]]@($dcs)
        $Global:lblDomain.Text = "Domain: $($dom.DNSRoot)"
        Set-Status "Domain info loaded." 100
    } catch { Set-Status "Error loading domain info." 0; Write-ADLog "ERROR Load-DomainInfo: $($_.Exception.Message)" "ERROR" }
}

function Load-OUTree {
    param([string]$Filter = "")
    if (-not (Ensure-ADModule)) { return }
    try {
        Set-Status "Loading OUs..." 10
    Write-Out "Get-ADOrganizationalUnit -Filter * -Properties CanonicalName,Description" "CMD"
        $treeOU.Items.Clear()
        $ous = Get-ADOrganizationalUnit -Filter * -Properties CanonicalName, Description | Sort-Object CanonicalName
        $Script:CachedOUs = $ous
        if ($Filter) { $ous = $ous | Where-Object { $_.Name -like "*$Filter*" -or $_.CanonicalName -like "*$Filter*" } }
        $nodeMap = @{}
        foreach ($ou in $ous) {
            $node = [System.Windows.Controls.TreeViewItem]::new()
            $node.Header = "  $($ou.Name)"
            $node.ToolTip = $ou.CanonicalName
            $node.IsExpanded = $true
            $nodeMap[$ou.DistinguishedName] = $node
        }
        foreach ($ou in $ous) {
            $dn = $ou.DistinguishedName
            $parentDN = $dn.Substring($dn.IndexOf(',') + 1)
            if ($nodeMap.ContainsKey($parentDN)) { [void]$nodeMap[$parentDN].Items.Add($nodeMap[$dn]) }
            else { [void]$treeOU.Items.Add($nodeMap[$dn]) }
        }
        $cnt = $Script:CachedOUs.Count
        $lblOUCount.Text = "Total OUs: $cnt"
        Set-Status "OU tree loaded ($cnt OUs)." 100
    } catch { Set-Status "Error loading OU tree." 0; Write-ADLog "ERROR Load-OUTree: $($_.Exception.Message)" "ERROR" }
}

function Load-Shares {
    try {
        Set-Status "Loading shares..." 10
    Write-Out "Get-WmiObject Win32_Share" "CMD"
        $shares = Get-WmiObject Win32_Share | ForEach-Object {
            [PSCustomObject]@{
                Name=$_.Name; Path=$_.Path; Description=$_.Description
                Type=switch($_.Type){0{"Disk"}1{"Print"}2{"Device"}3{"IPC"}2147483648{"Disk(Admin)"}2147483651{"IPC(Admin)"}default{"Other"}}
                MaxAllowed=if($_.MaximumAllowed -eq $null -or $_.MaximumAllowed -eq -1){"Unlimited"}else{"$($_.MaximumAllowed)"}
            }
        }
        $Script:CachedShares = $shares
        $gridShares.ItemsSource = [object[]]@($shares)
        $cnt = $shares.Count
        Set-Status "Shares loaded ($cnt)." 100
        Write-Out "Returned $cnt objects." "OK"
    } catch { Set-Status "Error loading shares." 0; Write-ADLog "ERROR Load-Shares: $($_.Exception.Message)" "ERROR" }
}


function Get-NTFSPermissionsRecursive {
    param([string]$Path, [string]$Identity, [string]$ShareName, [int]$MaxDepth = 2)
    $results = [System.Collections.Generic.List[object]]::new()
    $queue   = [System.Collections.Queue]::new()
    $queue.Enqueue(@{P=$Path; D=0})
    while ($queue.Count -gt 0) {
        $item  = $queue.Dequeue()
        $fpath = $item.P
        $depth = $item.D
        try {
            $acl = Get-Acl -Path $fpath -ErrorAction Stop
            foreach ($ace in $acl.Access) {
                $id    = $ace.IdentityReference.Value
                $uname = ($id -split "\\")[-1]
                if ($uname -ieq $Identity -or $id -ieq $Identity) {
                    $results.Add([PSCustomObject]@{
                        ShareName  = $ShareName
                        FolderPath = $fpath
                        Principal  = $id
                        AccessType = $ace.AccessControlType.ToString()
                        Rights     = $ace.FileSystemRights.ToString()
                        Inherited  = $ace.IsInherited
                        Source     = "NTFS"
                    })
                }
            }
        } catch { }
        if ($depth -lt $MaxDepth) {
            try {
                Get-ChildItem -Path $fpath -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                    $queue.Enqueue(@{P=$_.FullName; D=($depth+1)})
                }
            } catch { }
        }
    }
    return $results
}

function Check-UserSharePermissions {
    param([string]$Identity, [int]$ScanDepth = 2,
          [bool]$SkipSystemFolders = $true, [bool]$SkipAdminShares = $true, [bool]$LimitResults = $true)
    if ([string]::IsNullOrWhiteSpace($Identity)) { Show-Err "Enter a username or group."; return }
    if (-not $Script:CachedShares) { Load-Shares }
    # Reset cancel flag and show Stop button
    $Script:ScanCancelFlag = $false
    $btnStopScan.Visibility = [System.Windows.Visibility]::Visible
    if ($lblScanProgress) { $lblScanProgress.Text = "Starting scan for $Identity..." }
    # Disable buttons immediately on UI thread
    $btnCheckPerms.IsEnabled   = $false
    $btnBrowseFolder.IsEnabled = $false
    Write-Out "Check-UserSharePermissions -Identity '$Identity' -ScanDepth $ScanDepth -SkipSys:$SkipSystemFolders -SkipAdmin:$SkipAdminShares" "CMD"
    # Capture everything needed by the background thread
    $__id     = $Identity
    $__depth  = $ScanDepth
    $__skipSys   = $SkipSystemFolders
    $__skipAdmin = $SkipAdminShares
    $__limitRes  = $LimitResults
    $__shares = @($Script:CachedShares)   # copy
    $__grid   = $gridPerms
    $__logBuf = $Script:LogBuffer
    $__outBuf = $Script:OutputBuffer
    $__txtO   = $Global:txtOutput
    $__txtL   = $Global:txtLog
    $__pb     = $Global:pbMain
    $__lbl      = $Global:lblStatus
    $__scanLbl  = $lblScanProgress
    $__asc    = $Global:chkAutoScroll
    $__win    = $window
    $__btnC   = $btnCheckPerms
    $__btnB   = $btnBrowseFolder
    $__btnStop = $btnStopScan
    $__cachedRef = [ref]$Script:CachedPermsCheck
    $__cancelRef = $Script:ScanCancel  # synchronized hashtable - shared across runspaces

    $__blockStr = @'
        param($id,$depth,$skipSys,$skipAdmin,$limitRes,$shares,$grid,$logBuf,$outBuf,$txtO,$txtL,$pb,$lbl,$asc,$win,$btnC,$btnB,$btnStop,$cachedRef,$cancelRef,$scanLbl)
        function BW([string]$T,[string]$K="INFO"){
            $ts=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            $log="[$ts][$K] $T"
            $out=switch($K){"CMD"{"`n[$ts] PS> $T"}"RESULT"{"    $T"}"ERROR"{"[$ts][ERR] $T"}"OK"{"[$ts][ OK] $T"}"SEP"{"`n---- $T ----"}default{"[$ts][INF] $T"}}
            [void]$logBuf.AppendLine($log); [void]$outBuf.AppendLine($log)
            try{$txtL.Dispatcher.Invoke([action]{$txtL.AppendText($log+"`n");$txtL.ScrollToEnd()})}catch{}
            try{$txtO.Dispatcher.Invoke([action]{$txtO.AppendText($out+"`n");if($asc.IsChecked){$txtO.ScrollToEnd()}})}catch{}
        }
        function BS([string]$M,[int]$P=-1){
            try{$lbl.Dispatcher.Invoke([action]{$lbl.Text=$M})}catch{}
            try{if($P-ge 0){$pb.Dispatcher.Invoke([action]{$pb.Value=$P})}}catch{}
            try{if($scanLbl){$scanLbl.Dispatcher.Invoke([action]{$scanLbl.Text=$M})}}catch{}
            BW $M
        }
        BW "--- Checking permissions for: $id (depth=$depth) ---" "SEP"
        $sysFolderNames = @('$Recycle.Bin','$RECYCLE.BIN','System Volume Information','DfsrPrivate','$SysReset','$WinREAgent','Recovery')
        $results=[System.Collections.Generic.List[object]]::new()
        $limitWarned = $false
        $folderCount = 0

        # Filter admin shares if requested (shares ending in $)
        $sharesToScan = if($skipAdmin){
            $skipped = @($shares | Where-Object { $_.Name -like '*$' })
            if($skipped.Count -gt 0){ BW "Skipping admin shares: $($skipped.Name -join ', ')" "INFO" }
            @($shares | Where-Object { $_.Name -notlike '*$' })
        } else { $shares }

        $total=$sharesToScan.Count; $idx=0
        foreach($share in $sharesToScan){
            if($cancelRef.Value -or (Test-Path "$env:TEMP\ADMgr_StopScan.tmp" -EA SilentlyContinue)){ BW "Scan cancelled by user." "WARN"; break }
            $idx++; $pct=[int](($idx/[math]::Max($total,1))*88); $sn=$share.Name
            BS "[$idx/$total] $sn - $folderCount φάκελοι, $($results.Count) entries..." $pct
            $sp=$share.Path
            # Share-level ACL
            try{
                BW "  Get-WmiObject Win32_LogicalShareSecuritySetting -Filter ""Name='$sn'"" " "CMD"
                $ss=Get-WmiObject -Class Win32_LogicalShareSecuritySetting -Filter "Name='$($sn -replace "'","''")'" -EA SilentlyContinue
                if($ss){
                    $sd=$ss.GetSecurityDescriptor()
                    if($sd.ReturnValue -eq 0 -and $sd.Descriptor.DACL){
                        foreach($ace in $sd.Descriptor.DACL){
                            $tr=$ace.Trustee.Name; $dm=$ace.Trustee.Domain
                            $full=if($dm){"${dm}\${tr}"}else{$tr}
                            if($tr -ieq $id -or $full -ieq $id){
                                $mask=$ace.AccessMask
                                $rts=switch($mask){1179785{"Read"}1245631{"Change"}2032127{"Full Control"}default{"0x$("{0:X}"-f$mask)"}}
                                $at=if($ace.AceType-eq 0){"Allow"}else{"Deny"}
                                $results.Add([PSCustomObject]@{ShareName=$sn;FolderPath=$sp;Principal=$full;AccessType=$at;Rights=$rts;Inherited=$false;Source="Share ACL"})
                                BW "  SHARE ACL: $full | $at | $rts" "RESULT"
                            }
                        }
                    }
                }
            }catch{BW "  Share ACL error on $sn : $($_.Exception.Message)" "ERROR"}
            # NTFS scan
            if(-not [string]::IsNullOrWhiteSpace($sp) -and (Test-Path $sp -EA SilentlyContinue)){
                $queue=[System.Collections.Queue]::new(); $queue.Enqueue(@{P=$sp;D=0})
                while($queue.Count -gt 0){
                    if($cancelRef.Value -or (Test-Path "$env:TEMP\ADMgr_StopScan.tmp" -EA SilentlyContinue)){ BW "Scan cancelled by user." "WARN"; break }
                    $item=$queue.Dequeue(); $fp=$item.P; $fd=$item.D
                    $folderCount++
                    if($folderCount % 10 -eq 0){
                        BS "[$idx/$total] $sn - $folderCount φάκελοι σαρώθηκαν, $($results.Count) entries..." $pct
                    }
                    BW "  Get-Acl ""$fp""" "CMD"
                    try{
                        $acl=Get-Acl -Path $fp -EA Stop
                        foreach($ace in $acl.Access){
                            $pid=$ace.IdentityReference.Value; $un=($pid -split "\\")[-1]
                            if($un -ieq $id -or $pid -ieq $id){
                                $r=[PSCustomObject]@{ShareName=$sn;FolderPath=$fp;Principal=$pid;AccessType=$ace.AccessControlType.ToString();Rights=$ace.FileSystemRights.ToString();Inherited=$ace.IsInherited;Source="NTFS"}
                                $results.Add($r)
                                BW "  NTFS: $pid | $($ace.AccessControlType) | $($ace.FileSystemRights) | Inherited=$($ace.IsInherited)" "RESULT"
                            }
                        }
                    }catch{BW "  Get-Acl ERROR: $fp - $($_.Exception.Message)" "ERROR"}
                    # Limit results warning at 1000
                    if($limitRes -and -not $limitWarned -and $results.Count -ge 1000){
                        $limitWarned = $true
                        $msg = "Βρέθηκαν ήδη $($results.Count) entries ενώ το scan συνεχίζεται ($folderCount φάκελοι).`nΘέλεις να συνεχίσεις;`n`n(No = διακοπή scan)"
                        $dlgResult = [System.Windows.MessageBox]::Show($msg,"Όριο αποτελεσμάτων",[System.Windows.MessageBoxButton]::YesNo,[System.Windows.MessageBoxImage]::Warning)
                        if($dlgResult -ne [System.Windows.MessageBoxResult]::Yes){ $cancelRef.Value=$true; BW "Σταμάτησε από χρήστη στα 1000 entries." "WARN"; break }
                    }
                    if($fd -lt $depth){
                        try{
                            Get-ChildItem -Path $fp -Directory -EA SilentlyContinue | ForEach-Object {
                                if($skipSys -and ($sysFolderNames -contains $_.Name)){
                                    BW "  Skipping system folder: $($_.FullName)" "INFO"
                                } else {
                                    $queue.Enqueue(@{P=$_.FullName;D=($fd+1)})
                                }
                            }
                        }catch{}
                    }
                }
            }
        }
        if($results.Count -eq 0){
            $results.Add([PSCustomObject]@{ShareName="(none)";FolderPath="--";Principal=$id;AccessType="No explicit permissions found";Rights="--";Inherited="--";Source="--"})
            BW "Δεν βρέθηκαν άμεσες άδειες για '$id'" "WARN"
        }
        $cnt=$results.Count
        BS "Ολοκληρώθηκε - $cnt entries, $folderCount φάκελοι (depth=$depth)." 100
        BW "TOTAL: $cnt entries | $folderCount folders scanned for '$id'." "OK"
        try{$grid.Dispatcher.Invoke([action]{$grid.ItemsSource=[object[]]@($results)})}catch{}
        try{$cachedRef.Value=$results}catch{}
        try{$btnC.Dispatcher.Invoke([action]{$btnC.IsEnabled=$true})}catch{}
        try{$btnB.Dispatcher.Invoke([action]{$btnB.IsEnabled=$true})}catch{}
        try{$btnStop.Dispatcher.Invoke([action]{$btnStop.IsEnabled=$true; $btnStop.Visibility=[System.Windows.Visibility]::Collapsed})}catch{}
        try{Remove-Item "$env:TEMP\ADMgr_StopScan.tmp" -Force -EA SilentlyContinue}catch{}
        try{if($scanLbl){$scanLbl.Dispatcher.Invoke([action]{$scanLbl.Text=""})}}catch{}
'@
    $__block = [scriptblock]::Create($__blockStr)

    $rs=[System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState="STA"; $rs.ThreadOptions="ReuseThread"; $rs.Open()
    $ps=[System.Management.Automation.PowerShell]::Create()
    $ps.Runspace=$rs
    [void]$ps.AddScript($__block).AddArgument($__id).AddArgument($__depth).AddArgument($__skipSys).AddArgument($__skipAdmin).AddArgument($__limitRes).AddArgument($__shares).AddArgument($__grid).AddArgument($__logBuf).AddArgument($__outBuf).AddArgument($__txtO).AddArgument($__txtL).AddArgument($__pb).AddArgument($__lbl).AddArgument($__asc).AddArgument($__win).AddArgument($__btnC).AddArgument($__btnB).AddArgument($__btnStop).AddArgument($__cachedRef).AddArgument($__cancelRef).AddArgument($__scanLbl)
    $handle=$ps.BeginInvoke()
    # Cleanup timer
    $tmr=New-Object System.Windows.Threading.DispatcherTimer
    $tmr.Interval=[TimeSpan]::FromMilliseconds(400)
    $tmr.Add_Tick({
        if($handle.IsCompleted){
            $tmr.Stop()
            try{foreach($e in $ps.Streams.Error){Write-Out "BG ERROR: $e" "ERROR"};$ps.EndInvoke($handle)}catch{}
            $ps.Dispose(); $rs.Dispose()
            # Safety: ensure buttons restored even if background block failed
            try{$btnCheckPerms.IsEnabled=$true}catch{}
            try{$btnBrowseFolder.IsEnabled=$true}catch{}
            try{$btnStopScan.IsEnabled=$true;$btnStopScan.Visibility=[System.Windows.Visibility]::Collapsed}catch{}
        }
    })
    $tmr.Start()
    # Return immediately - execution continues in background
}

function Load-ADUsers {
    param([string]$Filter = "", [bool]$DisabledOnly = $false)
    if (-not (Ensure-ADModule)) { return }
    Write-OutputCmd "Get-ADUser -Filter * -Properties ..."
    try {
        Set-Status "Loading AD users..." 10
        $props = 'SamAccountName','DisplayName','mail','Enabled','Department','Title',
                 'DistinguishedName','WhenCreated','LastLogonDate','PasswordLastSet','PasswordNeverExpires','LockedOut'
        $all = Get-ADUser -Filter * -Properties $props | ForEach-Object {
            [PSCustomObject]@{
                Username=$_.SamAccountName; DisplayName=$_.DisplayName; Email=$_.mail
                Enabled=$_.Enabled; LockedOut=$_.LockedOut; Department=$_.Department; Title=$_.Title
                PwdLastSet=$_.PasswordLastSet; PwdNeverExpires=$_.PasswordNeverExpires
                LastLogon=$_.LastLogonDate; Created=$_.WhenCreated
                OU=($_.DistinguishedName -replace '^CN=[^,]+,','')
            }
        }
        if ($DisabledOnly) { $all = $all | Where-Object { $_.Enabled -eq $false } }
        if ($Filter)       { $all = $all | Where-Object { $_.Username -like "*$Filter*" -or $_.DisplayName -like "*$Filter*" -or $_.Email -like "*$Filter*" } }
        $Script:CachedUsers = $all
        $gridUsers.ItemsSource = [object[]]@($all)
        # Set up CollectionView for live filter
        $Script:UserCV = [System.Windows.Data.CollectionViewSource]::GetDefaultView($gridUsers.ItemsSource)
        $cnt = $all.Count
        $lblUsersRowCount.Text = "Found $cnt users"
        Set-Status "Users loaded ($cnt)." 100
        Write-Out "Returned $cnt objects." "OK"
        Write-OutputResult "Result: $cnt users loaded."
    } catch { Set-Status "Error loading users." 0; Write-ADLog "ERROR Load-ADUsers: $($_.Exception.Message)" "ERROR" }
}

function Load-ADGroups {
    param([string]$Filter = "", [bool]$IncludeNested = $false)
    if (-not (Ensure-ADModule)) { return }
    Write-OutputCmd "Get-ADGroup -Filter * -Properties ..."
    try {
        Set-Status "Loading AD groups..." 5
    Write-Out "Get-ADGroup -Filter * -Properties GroupCategory,GroupScope,Description,mail,ManagedBy,WhenCreated,Members" "CMD"
        $groups = Get-ADGroup -Filter * -Properties GroupCategory,GroupScope,Description,mail,ManagedBy,WhenCreated,Members
        if (-not $IncludeNested) {
            $all = $groups | ForEach-Object {
                [PSCustomObject]@{
                    Name=$_.Name; SAMAccount=$_.SamAccountName; Category=$_.GroupCategory; Scope=$_.GroupScope
                    Description=$_.Description; Email=$_.mail; ManagedBy=$_.ManagedBy
                    Members=$_.Members.Count; Created=$_.WhenCreated
                }
            }
        } else {
            Set-Status "Expanding nested members - please wait..." 15
            $rows = [System.Collections.Generic.List[object]]::new()
            $total = $groups.Count; $idx = 0
            foreach ($g in $groups) {
                $idx++
                $pct = [int](($idx / [math]::Max($total,1)) * 80) + 15
                $num = $idx; $gn = $g.Name
                Set-Status "Group ${num}/${total}: ${gn}" $pct
                try { $members = Get-ADGroupMember -Identity $g -Recursive -ErrorAction Stop } catch { $members = @() }
                if ($members) {
                    foreach ($m in $members) {
                        $rows.Add([PSCustomObject]@{GroupName=$g.Name;GroupSAM=$g.SamAccountName;MemberSAM=$m.SamAccountName;MemberName=$m.Name;ObjectClass=$m.objectClass})
                    }
                } else {
                    $rows.Add([PSCustomObject]@{GroupName=$g.Name;GroupSAM=$g.SamAccountName;MemberSAM="";MemberName="(empty)";ObjectClass=""})
                }
            }
            $all = $rows
        }
        if ($Filter) { $all = $all | Where-Object { $_.Name -like "*$Filter*" -or $_.SAMAccount -like "*$Filter*" } }
        $Script:CachedGroups = $all
        $gridGroups.ItemsSource = $all
        $cnt = $all.Count
        $lblGroupsRowCount.Text = "Found $cnt groups"
        Set-Status "Groups loaded ($cnt rows)." 100
    } catch { Set-Status "Error loading groups." 0; Write-ADLog "ERROR Load-ADGroups: $($_.Exception.Message)" "ERROR" }
}

function Load-ADComputers {
    param([string]$Filter = "")
    if (-not (Ensure-ADModule)) { return }
    Write-OutputCmd "Get-ADComputer -Filter * -Properties ..."
    try {
        Set-Status "Loading AD computers..." 10
    Write-Out "Get-ADComputer -Filter * -Properties DNSHostName,OperatingSystem,OperatingSystemVersion,Enabled,LastLogonDate,WhenCreated" "CMD"
        $all = Get-ADComputer -Filter * -Properties DNSHostName,OperatingSystem,OperatingSystemVersion,Enabled,LastLogonDate,WhenCreated | ForEach-Object {
            [PSCustomObject]@{
                Name=$_.Name; SAMAccount=$_.SamAccountName; DNSHostName=$_.DNSHostName
                OS=$_.OperatingSystem; OSVersion=$_.OperatingSystemVersion
                Enabled=$_.Enabled; LastLogon=$_.LastLogonDate; Created=$_.WhenCreated
            }
        }
        if ($Filter) { $all = $all | Where-Object { $_.Name -like "*$Filter*" -or $_.OS -like "*$Filter*" } }
        $Script:CachedComputers = $all
        $gridComputers.ItemsSource = [object[]]@($all)
        $cnt = $all.Count
        $lblComputersRowCount.Text = "Found $cnt computers"
        Set-Status "Computers loaded ($cnt)." 100
        Write-Out "Returned $cnt objects." "OK"
    } catch { Set-Status "Error loading computers." 0; Write-ADLog "ERROR Load-ADComputers: $($_.Exception.Message)" "ERROR" }
}

function Load-GPOs {
    if (-not (Ensure-GPModule)) { return }
    Write-OutputCmd "Get-GPO -All"
    try {
        Set-Status "Loading GPOs..." 10
    Write-Out "Get-GPO -All" "CMD"
        $all = Get-GPO -All | ForEach-Object {
            [PSCustomObject]@{
                Name=$_.DisplayName; ID=$_.Id.ToString(); Status=$_.GpoStatus; Owner=$_.Owner
                Created=$_.CreationTime; Modified=$_.ModificationTime
                UserVersion=$_.UserVersion; ComputerVersion=$_.ComputerVersion
            }
        }
        $gridGPOs.ItemsSource = [object[]]@($all)
        $cnt = $all.Count
        Set-Status "GPOs loaded ($cnt)." 100
        Write-Out "Returned $cnt objects." "OK"
    } catch { Set-Status "Error loading GPOs." 0; Write-ADLog "ERROR Load-GPOs: $($_.Exception.Message)" "ERROR" }
}

function Load-GPOLinks {
    if (-not (Ensure-ADModule)) { return }
    if (-not (Ensure-GPModule)) { return }
    try {
        Set-Status "Loading GPO links..." 5
    Write-Out "Get-ADOrganizationalUnit -Filter * -Properties gpLink | foreach: Get-GPO -Guid guid" "CMD"
        $rows  = [System.Collections.Generic.List[object]]::new()
        $ous   = Get-ADOrganizationalUnit -Filter * -Properties gpLink | Sort-Object CanonicalName
        $total = $ous.Count; $idx = 0
        foreach ($ou in $ous) {
            $idx++
            $pct = [int](($idx / [math]::Max($total,1)) * 85) + 10
            $num = $idx
            Set-Status "Scanning OU ${num}/${total}..." $pct
            if ($ou.LinkedGroupPolicyObjects) {
                foreach ($lnk in $ou.LinkedGroupPolicyObjects) {
                    $m = [regex]::Match($lnk, '\{([^}]+)\}')
                    if ($m.Success) {
                        $guid = $m.Groups[1].Value
                        try {
                            $gpo = Get-GPO -Guid $guid -ErrorAction Stop
                            $rows.Add([PSCustomObject]@{GPOName=$gpo.DisplayName;GPOID=$guid;OUName=$ou.Name;OUPath=$ou.CanonicalName;GPOStatus=$gpo.GpoStatus})
                        } catch {
                            $rows.Add([PSCustomObject]@{GPOName="(GUID: $guid)";GPOID=$guid;OUName=$ou.Name;OUPath=$ou.CanonicalName;GPOStatus="?"})
                        }
                    }
                }
            }
        }
        $gridGPOLinks.ItemsSource = [object[]]@($rows)
        $cnt = $rows.Count
        Set-Status "GPO links loaded ($cnt)." 100
    } catch { Set-Status "Error loading GPO links." 0; Write-ADLog "ERROR Load-GPOLinks: $($_.Exception.Message)" "ERROR" }
}

function Load-PasswordExpiry {
    param([int]$Days = 30)
    if (-not (Ensure-ADModule)) { return }
    try {
        Set-Status "Password expiry report (next $Days days)..." 10
        Write-Out "Get-ADDefaultDomainPasswordPolicy | Get-ADUser -Filter Enabled+PwdNeverExpires" "CMD"
        $maxPwdAge = (Get-ADDefaultDomainPasswordPolicy).MaxPasswordAge
        $now = Get-Date; $cutoff = $now.AddDays($Days)
        $all = Get-ADUser -Filter { Enabled -eq $true -and PasswordNeverExpires -eq $false } `
                    -Properties SamAccountName,DisplayName,mail,PasswordLastSet,Department |
               ForEach-Object {
                   $pls = $_.PasswordLastSet
                   $exp = if ($pls) { $pls + $maxPwdAge } else { $null }
                   $dl  = if ($exp) { [math]::Round(($exp - $now).TotalDays,0) } else { "N/A" }
                   [PSCustomObject]@{Username=$_.SamAccountName;DisplayName=$_.DisplayName;Email=$_.mail;Department=$_.Department;PwdLastSet=$pls;PwdExpires=$exp;DaysLeft=$dl}
               } | Where-Object { $_.PwdExpires -ne $null -and $_.PwdExpires -le $cutoff -and $_.PwdExpires -ge $now } | Sort-Object PwdExpires
        $Script:CachedPwdExpiry = $all
        $gridPwdExpiry.ItemsSource = [object[]]@($all)
        $cnt = $all.Count
        Set-Status "Password expiry: $cnt accounts expiring within $Days days." 100
    } catch { Set-Status "Error in password expiry." 0; Write-ADLog "ERROR Load-PasswordExpiry: $($_.Exception.Message)" "ERROR" }
}

function Load-InactiveUsers {
    param([int]$Days = 90)
    if (-not (Ensure-ADModule)) { return }
    try {
        Set-Status "Finding inactive users (>${Days}d)..." 10
        Write-Out "Get-ADUser -Filter Enabled -Properties LastLogonDate | Where LastLogonDate -lt cutoff" "CMD"
        $cutoff = (Get-Date).AddDays(-$Days)
        $all = Get-ADUser -Filter { Enabled -eq $true } -Properties SamAccountName,DisplayName,mail,LastLogonDate,WhenCreated,Department |
               Where-Object { $_.LastLogonDate -lt $cutoff -or $_.LastLogonDate -eq $null } |
               ForEach-Object {
                   $ll = $_.LastLogonDate
                   $ds = if ($ll) { [math]::Round(((Get-Date)-$ll).TotalDays,0) } else { "Never" }
                   [PSCustomObject]@{Username=$_.SamAccountName;DisplayName=$_.DisplayName;Email=$_.mail;Department=$_.Department;LastLogon=$ll;DaysSince=$ds;Created=$_.WhenCreated}
               } | Sort-Object LastLogon
        $Script:CachedInactiveU = $all
        $gridInactiveUsers.ItemsSource = [object[]]@($all)
        $cnt = $all.Count
        Set-Status "Inactive users: $cnt found." 100
    } catch { Set-Status "Error loading inactive users." 0; Write-ADLog "ERROR Load-InactiveUsers: $($_.Exception.Message)" "ERROR" }
}

function Load-InactiveComputers {
    param([int]$Days = 90)
    if (-not (Ensure-ADModule)) { return }
    try {
        Set-Status "Finding inactive computers (>${Days}d)..." 10
        Write-Out "Get-ADComputer -Filter Enabled -Properties LastLogonDate | Where LastLogonDate -lt cutoff" "CMD"
        $cutoff = (Get-Date).AddDays(-$Days)
        $all = Get-ADComputer -Filter { Enabled -eq $true } -Properties Name,OperatingSystem,LastLogonDate,WhenCreated,DNSHostName |
               Where-Object { $_.LastLogonDate -lt $cutoff -or $_.LastLogonDate -eq $null } |
               ForEach-Object {
                   $ll = $_.LastLogonDate
                   $ds = if ($ll) { [math]::Round(((Get-Date)-$ll).TotalDays,0) } else { "Never" }
                   [PSCustomObject]@{Name=$_.Name;DNSHostName=$_.DNSHostName;OS=$_.OperatingSystem;LastLogon=$ll;DaysSince=$ds;Created=$_.WhenCreated}
               } | Sort-Object LastLogon
        $Script:CachedInactiveC = $all
        $gridInactiveComp.ItemsSource = [object[]]@($all)
        $cnt = $all.Count
        Set-Status "Inactive computers: $cnt found." 100
    } catch { Set-Status "Error loading inactive computers." 0; Write-ADLog "ERROR Load-InactiveComputers: $($_.Exception.Message)" "ERROR" }
}

function Load-MemberOf {
    param([string]$Username)
    if (-not (Ensure-ADModule)) { return }
    if ([string]::IsNullOrWhiteSpace($Username)) { Show-Err "No user selected."; return }
    try {
        Set-Status "Loading groups for ${Username}..." 10
    Write-Out "Get-ADUser -Identity $Username -Properties MemberOf
Get-ADGroup -Identity (lt)dn(gt) -Properties Description,GroupCategory,GroupScope  # for each group" "CMD"
        $user = Get-ADUser -Identity $Username -Properties MemberOf -ErrorAction Stop
        $groups = $user.MemberOf | ForEach-Object {
            try {
                $g = Get-ADGroup -Identity $_ -Properties Description,GroupCategory,GroupScope
                [PSCustomObject]@{GroupName=$g.Name;SAMAccount=$g.SamAccountName;Category=$g.GroupCategory;Scope=$g.GroupScope;Description=$g.Description}
            } catch {
                [PSCustomObject]@{GroupName=$_;SAMAccount="?";Category="?";Scope="?";Description="?"}
            }
        } | Sort-Object GroupName
        $gridMemberOf.ItemsSource = [object[]]@($groups)
        $cnt = $groups.Count
        $lblMemberOfTitle.Text = "Groups for: $Username ($cnt groups)"
        $panelMemberOf.Visibility = "Visible"
        Set-Status "Member-of: $cnt groups for ${Username}." 100
    } catch { Set-Status "Error loading member-of." 0; Write-ADLog "ERROR Load-MemberOf: $($_.Exception.Message)" "ERROR" }
}

function Set-SelectedAccountState {
    param([bool]$Enable)
    if (-not (Ensure-ADModule)) { return }
    $items = $gridUsers.SelectedItems
    if ($items.Count -eq 0) { Show-Err "Select at least one user in the grid first."; return }
    $verb = if ($Enable) { "ENABLE" } else { "DISABLE" }
    $cnt  = $items.Count
    $res  = [System.Windows.MessageBox]::Show("Are you sure you want to $verb $cnt account(s)?","Confirm","YesNo","Warning")
    if ($res -ne "Yes") { return }
    $ok = 0; $fail = 0
    foreach ($item in $items) {
        $sam = $item.Username
        try {
            if ($Enable) { Enable-ADAccount  -Identity $sam -ErrorAction Stop }
            else         { Disable-ADAccount -Identity $sam -ErrorAction Stop }
            $ok++; Write-ADLog "${verb}: ${sam}"
        } catch { $fail++; Write-ADLog "ERROR ${verb} ${sam}: $($_.Exception.Message)" "ERROR" }
    }
    Show-Info "$verb complete: $ok succeeded, $fail failed."
    Load-ADUsers -Filter $txtUserFilter.Text.Trim() -DisabledOnly ($chkDisabledUsers.IsChecked -eq $true)
}

function Load-RecycleBin {
    if (-not (Ensure-ADModule)) { return }
    try {
        Set-Status "Checking AD Recycle Bin..." 10
    Write-Out "Get-ADOptionalFeature -Filter {Name -eq "Recycle Bin Feature"}
Get-ADObject -Filter {isDeleted -eq $true} -IncludeDeletedObjects -Properties *" "CMD"
        $rbF = Get-ADOptionalFeature -Filter { Name -eq "Recycle Bin Feature" } -ErrorAction SilentlyContinue
        if (-not $rbF -or $rbF.EnabledScopes.Count -eq 0) {
            Show-Info "AD Recycle Bin is NOT enabled in this domain.`n`nTo enable it run:`nEnable-ADOptionalFeature 'Recycle Bin Feature' -Scope ForestOrConfigurationSet -Target (Get-ADDomain).DNSRoot"
            Set-Status "AD Recycle Bin not enabled." 0; return
        }
        $del = Get-ADObject -Filter { isDeleted -eq $true } -IncludeDeletedObjects `
                   -Properties isDeleted,whenChanged,whenCreated,lastKnownParent,objectClass,displayName,sAMAccountName |
               ForEach-Object {
                   [PSCustomObject]@{Name=$_.Name;SAMAccount=$_.sAMAccountName;DisplayName=$_.displayName;ObjectClass=$_.objectClass;Deleted=$_.whenChanged;Created=$_.whenCreated;LastKnownParent=$_.lastKnownParent}
               } | Sort-Object Deleted -Descending
        $Script:CachedRecycleBin = $del
        $gridRecycleBin.ItemsSource = [object[]]@($del)
        $cnt = $del.Count
        Set-Status "Recycle Bin: $cnt deleted objects." 100
    } catch { Set-Status "Error loading Recycle Bin." 0; Write-ADLog "ERROR Load-RecycleBin: $($_.Exception.Message)" "ERROR" }
}

function Load-DNSZones {
    if (-not (Ensure-DnsModule)) { return }
    try {
        Set-Status "Loading DNS zones..." 10
    Write-Out "Get-DnsServerZone" "CMD"
        $zones = Get-DnsServerZone | ForEach-Object {
            [PSCustomObject]@{ZoneName=$_.ZoneName;ZoneType=$_.ZoneType;DsIntegrated=$_.IsDsIntegrated;ReverseLookup=$_.IsReverseLookupZone;ReplicationScope=$_.ReplicationScope;DynamicUpdate=$_.DynamicUpdate}
        }
        $Script:CachedDNSZones = $zones
        $gridDNSZones.ItemsSource = [object[]]@($zones)
        $cnt = $zones.Count
        Set-Status "DNS zones loaded ($cnt)." 100
        Write-Out "Returned $cnt objects." "OK"
    } catch { Set-Status "Error loading DNS zones." 0; Write-ADLog "ERROR Load-DNSZones: $($_.Exception.Message)" "ERROR" }
}

function Load-DNSZoneRecords {
    if (-not (Ensure-DnsModule)) { return }
    $sel = $gridDNSZones.SelectedItem
    if (-not $sel) { Show-Err "Select a DNS zone first."; return }
    $zn = $sel.ZoneName
    try {
        Set-Status "Loading records for zone ${zn}..." 10
        $recs = Get-DnsServerResourceRecord -ZoneName $zn | ForEach-Object {
            $rd = $_.RecordData; $data = ""
            try {
                if    ($rd.PSObject.Properties["IPv4Address"])    { $data = $rd.IPv4Address.IPAddressToString }
                elseif($rd.PSObject.Properties["IPv6Address"])    { $data = $rd.IPv6Address.IPAddressToString }
                elseif($rd.PSObject.Properties["NameServer"])     { $data = $rd.NameServer }
                elseif($rd.PSObject.Properties["MailExchange"])   { $data = "$($rd.Preference) $($rd.MailExchange)" }
                elseif($rd.PSObject.Properties["DomainName"])     { $data = $rd.DomainName }
                elseif($rd.PSObject.Properties["DescriptiveText"]){ $data = $rd.DescriptiveText }
                else { $data = ($rd | Out-String).Trim() }
            } catch { }
            [PSCustomObject]@{Name=$_.HostName;Type=$_.RecordType;TTL=$_.TimeToLive.ToString();Data=$data;Timestamp=$_.Timestamp}
        } | Sort-Object Type, Name
        $gridDNSRecords.ItemsSource = [object[]]@($recs)
        $cnt = $recs.Count
        Set-Status "Zone '${zn}': $cnt records." 100
    } catch { Set-Status "Error loading zone records." 0; Write-ADLog "ERROR Load-DNSZoneRecords: $($_.Exception.Message)" "ERROR" }
}

function Load-DHCPScopes {
    param([string]$Server = "localhost")
    if (-not (Ensure-DhcpModule)) { return }
    try {
        $srv = if ([string]::IsNullOrWhiteSpace($Server)) { "localhost" } else { $Server.Trim() }
        Set-Status "Loading DHCP scopes from
    Write-Out "Get-DhcpServerv4Scope -ComputerName $srv
Get-DhcpServerv4ScopeStatistics -ComputerName srv -ScopeId scopeId" "CMD"
        Set-Status "Loading DHCP scopes from ${srv}..." 10
        $scopes = Get-DhcpServerv4Scope -ComputerName $srv | ForEach-Object {
            $st = $null
            try { $st = Get-DhcpServerv4ScopeStatistics -ComputerName $srv -ScopeId $_.ScopeId -ErrorAction SilentlyContinue } catch { }
            $pct = if ($st -and $st.Total -gt 0) { "$([math]::Round(($st.InUse/$st.Total)*100,1))%" } else { "?" }
            [PSCustomObject]@{
                ScopeID=$_.ScopeId.ToString();Name=$_.Name;SubnetMask=$_.SubnetMask.ToString()
                StartRange=$_.StartRange.ToString();EndRange=$_.EndRange.ToString();State=$_.State
                LeaseDuration=$_.LeaseDuration.ToString()
                Total=if($st){$st.Total}else{"?"};InUse=if($st){$st.InUse}else{"?"};Available=if($st){$st.Available}else{"?"}
                "InUse%"=$pct;Description=$_.Description
            }
        }
        $Script:CachedDHCP = $scopes; $Script:DhcpServer = $srv
        $gridDHCP.ItemsSource = [object[]]@($scopes)
        $cnt = $scopes.Count
        Set-Status "DHCP scopes loaded ($cnt) from ${srv}." 100
    } catch { Set-Status "Error loading DHCP scopes." 0; Write-ADLog "ERROR Load-DHCPScopes: $($_.Exception.Message)" "ERROR" }
}

function Load-DHCPLeases {
    if (-not (Ensure-DhcpModule)) { return }
    $sel = $gridDHCP.SelectedItem
    if (-not $sel) { Show-Err "Select a DHCP scope first."; return }
    $scopeId = $sel.ScopeID
    $srv = if ($Script:DhcpServer) { $Script:DhcpServer } else { "localhost" }
        Set-Status "Loading leases for scope ${scopeId}..." 10
        Set-Status "Loading leases for scope
        Write-Out "Get-DhcpServerv4Lease -ComputerName srv -ScopeId scopeId" "CMD"
        $leases = Get-DhcpServerv4Lease -ComputerName $srv -ScopeId $scopeId |
                  ForEach-Object { [PSCustomObject]@{IPAddress=$_.IPAddress.ToString();ClientID=$_.ClientId;Hostname=$_.HostName;State=$_.AddressState;LeaseExpiry=$_.LeaseExpiryTime;Description=$_.Description} } |
                  Sort-Object IPAddress
        $gridLeases.ItemsSource = [object[]]@($leases)
        $cnt = $leases.Count
        Set-Status "DHCP leases for ${scopeId}: $cnt." 100
    } catch { Set-Status "Error loading DHCP leases." 0; Write-ADLog "ERROR Load-DHCPLeases: $($_.Exception.Message)" "ERROR" }
}
#endregion

#region ── USER PICKER DIALOG ─────────────────────────────────────────────────
function Show-ADPickerDialog {
    param(
        [string]$Title = "Pick from AD",
        [ValidateSet("Users","Groups")][string]$Mode = "Users"
    )
    if (-not (Ensure-ADModule)) { return @() }

    [xml]$px = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title" Width="680" Height="560" MinWidth="520" MinHeight="420"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize">
  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock Grid.Row="0" Text="Filter by SAMAccountName / Name / DisplayName:" FontWeight="SemiBold" Margin="0,0,0,8"/>
    <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,8">
      <TextBox x:Name="txtSearch" Width="430" Height="28" Padding="6,0" VerticalContentAlignment="Center"/>
      <Button x:Name="btnSearch" Content="Filter" Height="28" Padding="14,0" Margin="6,0,0,0" Background="#1E6EB5" Foreground="White" FontWeight="SemiBold"/>
      <TextBlock x:Name="lblCount" Text="" VerticalAlignment="Center" Margin="10,0,0,0" Foreground="#666" FontSize="11"/>
    </StackPanel>
    <ListBox x:Name="lstResults" Grid.Row="2" FontFamily="Consolas" FontSize="12" SelectionMode="Extended"/>
    <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
      <TextBlock Text="Ctrl+Click / Shift+Click για πολλαπλή επιλογή" VerticalAlignment="Center" Foreground="#666" FontSize="11" Margin="0,0,16,0"/>
      <Button x:Name="btnOK"     Content="OK"     Width="80" Height="30" Margin="0,0,8,0" Background="#1E6EB5" Foreground="White" FontWeight="SemiBold"/>
      <Button x:Name="btnCancel" Content="Cancel" Width="80" Height="30"/>
    </StackPanel>
  </Grid>
</Window>
"@

    $pr = [System.Xml.XmlNodeReader]::new($px)
    $pw = [Windows.Markup.XamlReader]::Load($pr)
    $pw.Owner = $Window

    # PS 5.1 safe pattern: keep every object used by event handlers in Script scope.
    $Script:ADPickerWindow     = $pw
    $Script:ADPickerMode       = $Mode
    $Script:ADPickerSearchCtrl = $pw.FindName("txtSearch")
    $Script:ADPickerListCtrl   = $pw.FindName("lstResults")
    $Script:ADPickerCountCtrl  = $pw.FindName("lblCount")
    $Script:ADPickerPicked     = @()
    $Script:ADPickerAllItems   = @()

    $Script:ADPickerDoAccept = {
        $picked = New-Object System.Collections.Generic.List[string]
        foreach ($item in @($Script:ADPickerListCtrl.SelectedItems)) {
            if ($null -ne $item.Tag -and -not [string]::IsNullOrWhiteSpace([string]$item.Tag)) {
                [void]$picked.Add([string]$item.Tag)
            }
        }
        $Script:ADPickerPicked = @($picked | Select-Object -Unique)
        $Script:ADPickerWindow.DialogResult = $true
        $Script:ADPickerWindow.Close()
    }

    $Script:ADPickerDoSearch = {
        $q = ""
        try { $q = $Script:ADPickerSearchCtrl.Text.Trim() } catch { $q = "" }
        $Script:ADPickerListCtrl.Items.Clear()

        $items = @($Script:ADPickerAllItems)
        if (-not [string]::IsNullOrWhiteSpace($q)) {
            $needle = "*${q}*"
            $items = @($items | Where-Object {
                $_.Sam -like $needle -or $_.Name -like $needle -or $_.DisplayName -like $needle
            })
        }

        foreach ($entry in @($items | Sort-Object Sam)) {
            $lbi = New-Object System.Windows.Controls.ListBoxItem
            $lbi.Content = $entry.Line
            $lbi.Tag = $entry.Sam
            [void]$Script:ADPickerListCtrl.Items.Add($lbi)
        }
        try { $Script:ADPickerCountCtrl.Text = "$($Script:ADPickerListCtrl.Items.Count) / $($Script:ADPickerAllItems.Count)" } catch { }
    }

    try {
        if ($Mode -eq "Groups") {
            $Script:ADPickerAllItems = @(
                Get-ADGroup -Filter * -Properties Description |
                    Select-Object SamAccountName,Name,Description |
                    ForEach-Object {
                        $sam = [string]$_.SamAccountName
                        $name = [string]$_.Name
                        $desc = [string]$_.Description
                        [PSCustomObject]@{
                            Sam = $sam
                            Name = $name
                            DisplayName = $desc
                            Line = ("{0,-28}  [{1}]  [Group]" -f $sam,$name)
                        }
                    }
            )
        } else {
            $Script:ADPickerAllItems = @(
                Get-ADUser -Filter * -Properties DisplayName |
                    Select-Object SamAccountName,Name,DisplayName |
                    ForEach-Object {
                        $sam = [string]$_.SamAccountName
                        $name = [string]$_.Name
                        $disp = [string]$_.DisplayName
                        if ([string]::IsNullOrWhiteSpace($disp)) { $disp = $name }
                        [PSCustomObject]@{
                            Sam = $sam
                            Name = $name
                            DisplayName = $disp
                            Line = ("{0,-28}  [{1}]  [User]" -f $sam,$disp)
                        }
                    }
            )
        }
    } catch {
        Show-Err "AD list load failed: $($_.Exception.Message)"
        return @()
    }

    & $Script:ADPickerDoSearch

    $pw.FindName("btnSearch").Add_Click({ & $Script:ADPickerDoSearch })
    $Script:ADPickerSearchCtrl.Add_TextChanged({ & $Script:ADPickerDoSearch })
    $Script:ADPickerSearchCtrl.Add_KeyDown({ param($s,$e); if ($e.Key -eq "Return") { & $Script:ADPickerDoSearch } })
    $Script:ADPickerListCtrl.Add_MouseDoubleClick({ & $Script:ADPickerDoAccept })
    $pw.FindName("btnOK").Add_Click({ & $Script:ADPickerDoAccept })
    $pw.FindName("btnCancel").Add_Click({ $Script:ADPickerWindow.Close() })

    $pw.ShowDialog() | Out-Null
    return @($Script:ADPickerPicked)
}

function Show-UserPickerDialog {
    $picks = Show-ADPickerDialog -Title "Pick User(s) from AD" -Mode "Users"
    if ($picks -and @($picks).Count -gt 0) { return @($picks)[0] }
    return $null
}
#endregion




function Scan-FolderPermissions {
    param([string]$Identity, [int]$ScanDepth = 3)
    # Open folder browser dialog
    $fb = New-Object System.Windows.Forms.FolderBrowserDialog
    $fb.Description  = "Select the folder to scan for NTFS permissions"
    $fb.ShowNewFolderButton = $false
    if ($fb.ShowDialog() -ne "OK") { return }
    $rootPath = $fb.SelectedPath
    if ([string]::IsNullOrWhiteSpace($Identity)) { Show-Err "Enter a username or group first."; return }
    Write-OutputCmd "Scan-FolderPermissions -Path '$rootPath' -Identity '$Identity' -Depth $ScanDepth"
    Set-Status "Scanning folder '${rootPath}' for permissions of '${Identity}'..." 5
    $results = Get-NTFSPermissionsRecursive -Path $rootPath -Identity $Identity -ShareName "(folder scan)" -MaxDepth $ScanDepth
    foreach ($r in $results) {
        if (-not $r.Inherited) {
            Write-OutputResult "  FOUND: $($r.FolderPath) | $($r.Principal) | $($r.AccessType) | $($r.Rights)"
        }
    }
    if ($results.Count -eq 0) {
        $results = @([PSCustomObject]@{ShareName="(folder scan)";FolderPath=$rootPath;Principal=$Identity;AccessType="No explicit permissions found";Rights="--";Inherited="--";Source="--"})
        Write-OutputResult "  No explicit permissions found for '$Identity' under '$rootPath'"
    }
    $Script:CachedPermsCheck = $results
    $gridPerms.ItemsSource   = [object[]]@($results)
    $cnt = $results.Count
    Set-Status "Folder scan done - $cnt entries (depth=$ScanDepth)." 100
}



#region ── HEATMAP USER POPUP ─────────────────────────────────────────────────
function Show-HeatmapUserPopup {
    param([string]$Label)
    if (-not $Script:HeatmapBucketUsers -or -not $Script:HeatmapBucketUsers.ContainsKey($Label)) {
        Show-Info "No users in bucket '$Label' or heatmap not loaded yet."
        return
    }
    $userList = $Script:HeatmapBucketUsers[$Label]
    [xml]$popXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Users: BUCKET_LABEL" Width="560" Height="460"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize" Background="#F8F9FA">
  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock Grid.Row="0" x:Name="lblPopTitle" FontSize="14" FontWeight="Bold"
               Foreground="#1E3A5F" Margin="0,0,0,8"/>
    <DataGrid Grid.Row="1" x:Name="dgPopUsers" AutoGenerateColumns="True" IsReadOnly="True"
              GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#EEE"
              RowBackground="White" AlternatingRowBackground="#F8F9FA"
              FontSize="12" BorderBrush="#DDE1E7" BorderThickness="1"
              HeadersVisibility="Column" CanUserSortColumns="True"/>
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
      <Button x:Name="btnPopExport" Content="Export CSV" Width="100" Height="28"
              Background="#2E7D32" Foreground="White" BorderThickness="0"
              FontWeight="SemiBold" Cursor="Hand" Margin="0,0,8,0"/>
      <Button x:Name="btnPopClose"  Content="Close"      Width="80"  Height="28"
              BorderBrush="#CCC" BorderThickness="1" Cursor="Hand"/>
    </StackPanel>
  </Grid>
</Window>
"@
    $popXaml.Window.Title = "Users: $Label"
    $pr3 = [System.Xml.XmlNodeReader]::new($popXaml)
    $pw3 = [Windows.Markup.XamlReader]::Load($pr3)
    $pw3.Owner = $Window
    $pw3.FindName("lblPopTitle").Text = "$Label  ($($userList.Count) users)"
    $pw3.FindName("dgPopUsers").ItemsSource = [object[]]@($userList)
    $pw3.FindName("btnPopClose").Add_Click({ $pw3.Close() })
    $pw3.FindName("btnPopExport").Add_Click({
        $path = Pick-SavePath -Default "HeatmapUsers_$($Label -replace '\s','-').csv"
        if ($path) {
            $userList | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8
            Show-Info "Exported to:`n$path"
        }
    })
    $pw3.ShowDialog() | Out-Null
}
#endregion

#region ── RESET PASSWORD ────────────────────────────────────────────────────
function Reset-SelectedPassword {
    if (-not (Ensure-ADModule)) { return }
    $sel = $gridUsers.SelectedItem
    if (-not $sel) { Show-Err "Select a user first."; return }
    $sam = $sel.Username; $dispName = $sel.DisplayName
    # Simple input dialog for new password
    [xml]$pdXml = '<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="Reset Password" Width="380" Height="230" WindowStartupLocation="CenterOwner" ResizeMode="NoResize" Background="#F8F9FA"><StackPanel Margin="24,20"><TextBlock x:Name="lblUser" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,4" Foreground="#1E3A5F"/><TextBlock Text="New password (blank = auto-generate 16-char random):" FontSize="11" Foreground="#777" Margin="0,0,0,8"/><PasswordBox x:Name="pbPwd" Height="30" Padding="8,0" FontSize="12" BorderBrush="#CCC" BorderThickness="1" Margin="0,0,0,8"/><CheckBox x:Name="chkMustChange" Content="User must change at next logon" IsChecked="True" FontSize="11" Margin="0,0,0,16"/><StackPanel Orientation="Horizontal" HorizontalAlignment="Right"><Button x:Name="btnOK" Content="Reset" Width="80" Height="28" Background="#E65100" Foreground="White" FontWeight="SemiBold" BorderThickness="0" Cursor="Hand" Margin="0,0,8,0"/><Button x:Name="btnCancel" Content="Cancel" Width="80" Height="28" BorderBrush="#CCC" BorderThickness="1" Cursor="Hand"/></StackPanel></StackPanel></Window>'
    $pr2 = [System.Xml.XmlNodeReader]::new($pdXml)
    $pw2 = [Windows.Markup.XamlReader]::Load($pr2); $pw2.Owner = $Window
    $pw2.FindName("lblUser").Text = "Reset password for: $sam ($dispName)"
    $pbPwd2   = $pw2.FindName("pbPwd")
    $chkMust2 = $pw2.FindName("chkMustChange")
    $result2  = $false
    $pw2.FindName("btnCancel").Add_Click({ $pw2.Close() })
    $pw2.FindName("btnOK").Add_Click({ $result2 = $true; $pw2.Close() })
    $pw2.ShowDialog() | Out-Null
    if (-not $result2) { return }
    $plain = $pbPwd2.Password
    if ([string]::IsNullOrWhiteSpace($plain)) {
        $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789!@#$%'
        $plain = -join ((0..15) | ForEach-Object { $chars[(Get-Random -Max $chars.Length)] })
    }
    try {
        $sec = ConvertTo-SecureString $plain -AsPlainText -Force
        Set-ADAccountPassword -Identity $sam -NewPassword $sec -Reset -ErrorAction Stop
        if ($chkMust2.IsChecked) { Set-ADUser -Identity $sam -ChangePasswordAtLogon $true -ErrorAction Stop }
        Write-Out "Set-ADAccountPassword -Identity $sam -Reset" "CMD"
        Show-Info "Password reset OK for $sam`nNew password: $plain`n`n$(if($chkMust2.IsChecked){'User must change at next logon.'} else {'No forced change.'})"
        Write-Out "Password reset OK for: $sam" "OK"
    } catch { Show-Err "Failed: $($_.Exception.Message)"; Write-Out "ERROR reset pwd $sam : $($_.Exception.Message)" "ERROR" }
}
#endregion

#region ── UNLOCK ACCOUNT ────────────────────────────────────────────────────
function Unlock-SelectedAccount {
    if (-not (Ensure-ADModule)) { return }
    $sel = $gridUsers.SelectedItem
    if (-not $sel) { Show-Err "Select a user first."; return }
    $sam = $sel.Username
    if ($sel.LockedOut -ne $true) { Show-Info "$sam is not locked out."; return }
    try {
        Write-Out "Unlock-ADAccount -Identity $sam" "CMD"
        Unlock-ADAccount -Identity $sam -ErrorAction Stop
        Show-Info "Account unlocked: $sam"
        Write-Out "Unlock OK: $sam" "OK"
        Load-ADUsers -Filter $txtUserFilter.Text.Trim() -DisabledOnly ($chkDisabledUsers.IsChecked -eq $true)
    } catch { Show-Err "Failed: $($_.Exception.Message)"; Write-Out "ERROR unlock $sam : $($_.Exception.Message)" "ERROR" }
}
#endregion

#region ── LAST LOGON HEATMAP ────────────────────────────────────────────────
function Load-LastLogonHeatmap {
    if (-not (Ensure-ADModule)) { return }
    try {
        Set-Status "Loading logon heatmap..." 10
        Write-Out "Get-ADUser -Filter Enabled -Properties LastLogonDate" "CMD"
        $now   = Get-Date
        $users = Get-ADUser -Filter { Enabled -eq $true } -Properties LastLogonDate
        $buckets = [ordered]@{
            "Today / Yesterday"  = 0
            "2 - 7 days"         = 0
            "8 - 30 days"        = 0
            "31 - 90 days"       = 0
            "91 - 180 days"      = 0
            "Over 180 days"      = 0
            "Never logged on"    = 0
        }
        foreach ($u in $users) {
            if ($null -eq $u.LastLogonDate) { $buckets["Never logged on"]++; continue }
            $days = ($now - $u.LastLogonDate).TotalDays
            if    ($days -le 2)   { $buckets["Today / Yesterday"]++ }
            elseif($days -le 7)   { $buckets["2 - 7 days"]++        }
            elseif($days -le 30)  { $buckets["8 - 30 days"]++       }
            elseif($days -le 90)  { $buckets["31 - 90 days"]++      }
            elseif($days -le 180) { $buckets["91 - 180 days"]++     }
            else                  { $buckets["Over 180 days"]++     }
        }
        $total = ($users | Measure-Object).Count
        $colorMap = @{
            "Today / Yesterday" = "#27AE60"
            "2 - 7 days"        = "#52BE80"
            "8 - 30 days"       = "#F39C12"
            "31 - 90 days"      = "#E67E22"
            "91 - 180 days"     = "#E74C3C"
            "Over 180 days"     = "#922B21"
            "Never logged on"   = "#7F8C8D"
        }
        # Store user details per bucket for click-through
        $Script:HeatmapBucketUsers = @{}
        foreach ($u in $users) {
            $ll = $u.LastLogonDate
            $days2 = if ($ll) { ($now - $ll).TotalDays } else { 99999 }
            $bucket2 = if     ($days2 -le 2)   { "Today / Yesterday" }
                       elseif ($days2 -le 7)   { "2 - 7 days"        }
                       elseif ($days2 -le 30)  { "8 - 30 days"       }
                       elseif ($days2 -le 90)  { "31 - 90 days"      }
                       elseif ($days2 -le 180) { "91 - 180 days"     }
                       elseif ($days2 -lt 9999){ "Over 180 days"     }
                       else                    { "Never logged on"   }
            if (-not $Script:HeatmapBucketUsers.ContainsKey($bucket2)) {
                $Script:HeatmapBucketUsers[$bucket2] = [System.Collections.Generic.List[object]]::new()
            }
            [void]$Script:HeatmapBucketUsers[$bucket2].Add([PSCustomObject]@{
                Username    = $u.SamAccountName
                DisplayName = $u.DisplayName
                LastLogon   = $ll
                DaysAgo     = if ($ll) { [math]::Round($days2,0) } else { "Never" }
            })
        }

        $icHeatmap.Dispatcher.Invoke([action]{
            $icHeatmap.Items.Clear()
            foreach ($kv in $buckets.GetEnumerator()) {
                $label = $kv.Key; $count = $kv.Value
                $pct   = if ($total -gt 0) { [math]::Round($count / $total * 100, 1) } else { 0 }
                $hex   = if ($colorMap.ContainsKey($label)) { $colorMap[$label] } else { "#888888" }
                $brush = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString($hex))
                $tile  = New-Object System.Windows.Controls.Border
                $tile.Background   = $brush
                $tile.CornerRadius = [System.Windows.CornerRadius]8
                $tile.Margin       = [System.Windows.Thickness]4
                $tile.Padding      = [System.Windows.Thickness]"14,10,14,10"
                $tile.MinWidth     = 130
                $tile.Cursor       = [System.Windows.Input.Cursors]::Hand
                $tile.ToolTip      = "Click to see users in this group"
                # Store label in Tag for click handler
                $tile.Tag = $label
                $sp = New-Object System.Windows.Controls.StackPanel
                $t1 = New-Object System.Windows.Controls.TextBlock
                $t1.Text       = $label
                $t1.Foreground = [System.Windows.Media.Brushes]::White
                $t1.FontSize   = 11
                $t2 = New-Object System.Windows.Controls.TextBlock
                $t2.Text       = "$count  ($pct%)"
                $t2.Foreground = [System.Windows.Media.Brushes]::White
                $t2.FontSize   = 18
                $t2.FontWeight = [System.Windows.FontWeights]::Bold
                [void]$sp.Children.Add($t1)
                [void]$sp.Children.Add($t2)
                $tile.Child = $sp
                # Click -> show inline detail grid
                $tile.Add_MouseLeftButtonUp({
                    param($src, $e2)
                    $bucketLabel = $src.Tag
                    if ($Script:HeatmapBucketUsers -and $Script:HeatmapBucketUsers.ContainsKey($bucketLabel)) {
                        $gridHeatmapDetail.ItemsSource = [object[]]@($Script:HeatmapBucketUsers[$bucketLabel])
                        $lblHeatmapDetailTitle.Text = "$bucketLabel  ($($Script:HeatmapBucketUsers[$bucketLabel].Count) users)"
                        $borderHeatmapDetail.Visibility = [System.Windows.Visibility]::Visible
                    }
                })
                [void]$icHeatmap.Items.Add($tile)
            }
        })
        $lblHeatmapInfo.Text = "Total enabled users: $total  |  Updated: $(Get-Date -Format 'HH:mm:ss')"
        Write-Out "Heatmap OK: $total enabled users." "OK"
        Set-Status "Heatmap loaded." 100
    } catch {
        Set-Status "Error loading heatmap." 0
        Write-Out "ERROR Load-LastLogonHeatmap: $($_.Exception.Message)" "ERROR"
    }
}
#endregion

#region ── STALE COMPUTERS ───────────────────────────────────────────────────
function Load-StaleComputers {
    param([int]$Days = 30)
    if (-not (Ensure-ADModule)) { return }
    try {
        Set-Status "Finding stale computers (password not changed in >$Days days)..." 10
        Write-Out "Get-ADComputer -Filter * -Properties PasswordLastSet,LastLogonDate,OperatingSystem | Where PasswordLastSet -lt $(( Get-Date ).AddDays(-$Days))" "CMD"
        $cutoff = (Get-Date).AddDays(-$Days)
        $all = Get-ADComputer -Filter * -Properties PasswordLastSet,LastLogonDate,OperatingSystem,Enabled,DNSHostName |
               Where-Object { $_.Enabled -eq $true -and ($_.PasswordLastSet -lt $cutoff -or $null -eq $_.PasswordLastSet) } |
               ForEach-Object {
                   $pls = $_.PasswordLastSet
                   $age = if ($pls) { [math]::Round(((Get-Date)-$pls).TotalDays,0) } else { "Never" }
                   $ll  = $_.LastLogonDate
                   $lla = if ($ll)  { [math]::Round(((Get-Date)-$ll).TotalDays,0)  } else { "Never" }
                   [PSCustomObject]@{
                       Name            = $_.Name
                       DNSHostName     = $_.DNSHostName
                       OS              = $_.OperatingSystem
                       PwdLastSet      = $pls
                       PwdAgeDays      = $age
                       LastLogon       = $ll
                       LastLogonDays   = $lla
                       DistinguishedName = $_.DistinguishedName
                   }
               } | Sort-Object PwdAgeDays -Descending
        $Script:CachedStale  = $all
        $gridStale.ItemsSource = [object[]]@($all)
        $cnt = $all.Count
        Set-Status "Stale computers: $cnt found (>${Days}d)." 100
        Write-Out "Stale computers: $cnt found (>${Days}d password age)." "OK"
    } catch { Set-Status "Error loading stale computers." 0; Write-Out "ERROR Load-StaleComputers: $($_.Exception.Message)" "ERROR" }
}
#endregion

#region ── GROUP MEMBERSHIP DIFF ─────────────────────────────────────────────
function Run-GroupDiff {
    param([string]$UserA, [string]$UserB)
    if (-not (Ensure-ADModule)) { return }
    if ([string]::IsNullOrWhiteSpace($UserA) -or [string]::IsNullOrWhiteSpace($UserB)) {
        Show-Err "Enter both user SAMAccountNames."; return
    }
    try {
        Set-Status "Comparing group memberships..." 10
        Write-Out "Get-ADUser -Identity $UserA -Properties MemberOf" "CMD"
        Write-Out "Get-ADUser -Identity $UserB -Properties MemberOf" "CMD"
        $uA = Get-ADUser -Identity $UserA -Properties MemberOf -ErrorAction Stop
        $uB = Get-ADUser -Identity $UserB -Properties MemberOf -ErrorAction Stop
        $grpsA = @{}; $grpsB = @{}
        foreach ($dn in @($uA.MemberOf)) {
            try { $g = Get-ADGroup $dn; $grpsA[$g.SamAccountName] = $g.Name } catch { }
        }
        foreach ($dn in @($uB.MemberOf)) {
            try { $g = Get-ADGroup $dn; $grpsB[$g.SamAccountName] = $g.Name } catch { }
        }
        $allGroups = ($grpsA.Keys + $grpsB.Keys) | Sort-Object -Unique
        $rows = $allGroups | ForEach-Object {
            $sam = $_
            $inA = $grpsA.ContainsKey($sam)
            $inB = $grpsB.ContainsKey($sam)
            $status = if ($inA -and $inB) { "Both" }
                      elseif ($inA)        { "Only $UserA" }
                      else                 { "Only $UserB" }
            [PSCustomObject]@{
                GroupName = if ($grpsA[$sam]) { $grpsA[$sam] } else { $grpsB[$sam] }
                SAMAccount= $sam
                InUserA   = $inA
                InUserB   = $inB
                Status    = $status
            }
        }
        $Script:CachedGroupDiff  = $rows
        $gridGroupDiff.ItemsSource = [object[]]@($rows)
        $onlyA = ($rows | Where-Object { $_.Status -ne "Both" -and $_.InUserA -eq $true -and $_.InUserB -eq $false }).Count
        $onlyB = ($rows | Where-Object { $_.Status -ne "Both" -and $_.InUserA -eq $false -and $_.InUserB -eq $true }).Count
        $both  = ($rows | Where-Object { $_.InUserA -eq $true  -and $_.InUserB -eq $true }).Count
        Set-Status "Group diff: $both shared, $onlyA only in $UserA, $onlyB only in $UserB." 100
        Write-Out "Diff: $both shared | $onlyA only-$UserA | $onlyB only-$UserB" "OK"
    } catch { Set-Status "Error comparing groups." 0; Write-Out "ERROR Run-GroupDiff: $($_.Exception.Message)" "ERROR" }
}
#endregion

#region ── AD HEALTH CHECK ───────────────────────────────────────────────────
function Run-ADHealthCheck {
    if (-not (Ensure-ADModule)) { return }
    $lblHealthStatus.Text = "Running health check..."
    $btnRunHealth.IsEnabled = $false
    $rows = [System.Collections.Generic.List[object]]::new()

    function Add-Check {
        param([string]$Category,[string]$Check,[string]$Status,[string]$Detail)
        $rows.Add([PSCustomObject]@{ Category=$Category; Check=$Check; Status=$Status; Detail=$Detail })
        $icon = if ($Status -eq "OK") { "OK" } elseif ($Status -eq "WARN") { "WARN" } else { "ERROR" }
        $__kind = if ($Status -eq "OK") { "OK" } elseif ($Status -eq "WARN") { "WARN" } else { "ERROR" }
        Write-Out "  [$($Status)] $Category - $Check : $Detail" $__kind
    }

    Write-Out "--- AD Health Check ---" "SEP"
    try {
        # 1. Domain basic
        try {
            $dom = Get-ADDomain -ErrorAction Stop
            Add-Check "Domain" "Get-ADDomain" "OK" "Domain: $($dom.DNSRoot) | Level: $($dom.DomainMode)"
        } catch { Add-Check "Domain" "Get-ADDomain" "ERROR" $_.Exception.Message }

        # 2. PDC ping
        try {
            $pdc = (Get-ADDomain).PDCEmulator
            Write-Out "Test-Connection $pdc -Count 1 -Quiet" "CMD"
            $ping = Test-Connection -ComputerName $pdc -Count 1 -Quiet -ErrorAction SilentlyContinue
            if ($ping) { Add-Check "Connectivity" "PDC Ping ($pdc)" "OK" "Reachable" }
            else { Add-Check "Connectivity" "PDC Ping ($pdc)" "WARN" "No response (firewall?)" }
        } catch { Add-Check "Connectivity" "PDC Ping" "ERROR" $_.Exception.Message }

        # 3. All DCs ping + services
        try {
            $dcs = Get-ADDomainController -Filter * -ErrorAction Stop
            foreach ($dc in $dcs) {
                $dcName = $dc.HostName
                Write-Out "Test-Connection $dcName -Count 1 -Quiet" "CMD"
                $ping2 = Test-Connection -ComputerName $dcName -Count 1 -Quiet -ErrorAction SilentlyContinue
                if ($ping2) { Add-Check "DC Connectivity" "Ping $dcName" "OK" "Reachable ($($dc.IPv4Address))" }
                else { Add-Check "DC Connectivity" "Ping $dcName" "WARN" "No response" }
                # Test LDAP port 389
                Write-Out "Test-NetConnection $dcName -Port 389" "CMD"
                try {
                    $ldap = New-Object System.Net.Sockets.TcpClient
                    $ar = $ldap.BeginConnect($dcName, 389, $null, $null)
                    $ok = $ar.AsyncWaitHandle.WaitOne(2000)
                    $ldap.Close()
                    if ($ok) { Add-Check "DC Services" "LDAP:389 $dcName" "OK" "Port open" }
                    else { Add-Check "DC Services" "LDAP:389 $dcName" "WARN" "Port not responding" }
                } catch { Add-Check "DC Services" "LDAP:389 $dcName" "ERROR" $_.Exception.Message }
            }
        } catch { Add-Check "DC Connectivity" "Get-ADDomainController" "ERROR" $_.Exception.Message }

        # 4. Replication status via repadmin
        Write-Out "repadmin /showrepl /csv" "CMD"
        try {
            $replOut = & repadmin /showrepl /errorsonly 2>&1
            if ($LASTEXITCODE -eq 0 -and (-not $replOut -or $replOut.Count -eq 0)) {
                Add-Check "Replication" "repadmin /showrepl" "OK" "No replication errors"
            } else {
                $errCount = if ($replOut) { $replOut.Count } else { 0 }
                if ($errCount -gt 0) {
                    Add-Check "Replication" "repadmin /showrepl" "ERROR" "$errCount error(s): $($replOut[0])"
                } else {
                    Add-Check "Replication" "repadmin /showrepl" "OK" "No errors reported"
                }
            }
        } catch { Add-Check "Replication" "repadmin" "WARN" "repadmin not available or failed" }

        # 5. SYSVOL share
        try {
            $pdc2 = (Get-ADDomain).PDCEmulator
            Write-Out "Test-Path \\\\$pdc2\\SYSVOL" "CMD"
            $sysvolPath = "\\$pdc2\SYSVOL"
            if (Test-Path $sysvolPath -ErrorAction Stop) { Add-Check "SYSVOL" "SYSVOL share ($pdc2)" "OK" "Accessible: $sysvolPath" }
            else { Add-Check "SYSVOL" "SYSVOL share ($pdc2)" "WARN" "Not accessible: $sysvolPath" }
        } catch { Add-Check "SYSVOL" "SYSVOL share" "ERROR" $_.Exception.Message }

        # 6. NETLOGON share
        try {
            $pdc3 = (Get-ADDomain).PDCEmulator
            Write-Out "Test-Path \\\\$pdc3\\NETLOGON" "CMD"
            $nlPath = "\\$pdc3\NETLOGON"
            if (Test-Path $nlPath -ErrorAction Stop) { Add-Check "NETLOGON" "NETLOGON share ($pdc3)" "OK" "Accessible: $nlPath" }
            else { Add-Check "NETLOGON" "NETLOGON share ($pdc3)" "WARN" "Not accessible: $nlPath" }
        } catch { Add-Check "NETLOGON" "NETLOGON share" "ERROR" $_.Exception.Message }

        # 7. Password policy
        try {
            Write-Out "Get-ADDefaultDomainPasswordPolicy" "CMD"
            $pp = Get-ADDefaultDomainPasswordPolicy -ErrorAction Stop
            $minLen = $pp.MinPasswordLength
            $status3 = if ($minLen -ge 8) { "OK" } else { "WARN" }
            Add-Check "Password Policy" "Min password length" $status3 "MinLength=$minLen | MaxAge=$($pp.MaxPasswordAge.Days)d | Complexity=$($pp.ComplexityEnabled)"
        } catch { Add-Check "Password Policy" "Get-ADDefaultDomainPasswordPolicy" "ERROR" $_.Exception.Message }

        # 8. Locked out users count
        try {
            Write-Out "Search-ADAccount -LockedOut" "CMD"
            $locked = (Search-ADAccount -LockedOut -ErrorAction Stop).Count
            $stat4 = if ($locked -eq 0) { "OK" } elseif ($locked -le 5) { "WARN" } else { "ERROR" }
            Add-Check "User Status" "Locked out accounts" $stat4 "$locked accounts currently locked out"
        } catch { Add-Check "User Status" "Search-ADAccount -LockedOut" "WARN" "Could not query: $($_.Exception.Message)" }

        # 9. Disabled DC check
        try {
            $dcs2 = Get-ADDomainController -Filter *
            $disabledDC = $dcs2 | Where-Object { $_.Enabled -eq $false }
            if ($disabledDC) { Add-Check "DC Health" "Disabled DCs" "WARN" "$($disabledDC.Count) disabled DC(s): $($disabledDC.Name -join ', ')" }
            else { Add-Check "DC Health" "Disabled DCs" "OK" "All DCs enabled" }
        } catch { Add-Check "DC Health" "Disabled DC check" "WARN" $_.Exception.Message }

    } catch { Add-Check "General" "Health Check" "ERROR" "Unexpected error: $($_.Exception.Message)" }

    $Script:CachedHealth = $rows
    $gridHealth.ItemsSource = [object[]]@($rows)
    $hOK   = ($rows | Where-Object { $_.Status -eq "OK"    }).Count
    $hWARN = ($rows | Where-Object { $_.Status -eq "WARN"  }).Count
    $hERR  = ($rows | Where-Object { $_.Status -eq "ERROR" }).Count
    $hTot  = $rows.Count
    $lblHealthStatus.Text = "Total: $hTot | OK: $hOK | WARN: $hWARN | ERROR: $hERR"
    Set-Status "Health check done: $hOK OK, $hWARN WARN, $hERR ERROR." 100
    Write-Out "Health check complete: $hOK OK | $hWARN WARN | $hERR ERROR" "OK"
    $btnRunHealth.IsEnabled = $true
}
#endregion

#region ── DARK MODE ─────────────────────────────────────────────────────────
function Toggle-DarkMode {
    $Script:IsDarkMode = -not $Script:IsDarkMode
    if ($Script:IsDarkMode) {
        $btnDarkMode.Content = [char]0x263D  # crescent = dark mode active, click for light
        $btnDarkMode.ToolTip = "Switch to Light mode"
        # Dark backgrounds
        $Window.Background = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(26,26,46))
        foreach ($ctrl in @($tabMain)) {
            try { $ctrl.Background = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(26,26,46)) } catch {}
        }
        # Try to recolor all Border cards
        $allBorders = [System.Collections.Generic.List[object]]::new()
        function Collect-Borders { param($parent)
            if ($null -eq $parent) { return }
            try {
                for ($ci = 0; $ci -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($parent); $ci++) {
                    $child = [System.Windows.Media.VisualTreeHelper]::GetChild($parent, $ci)
                    if ($child -is [System.Windows.Controls.Border]) { [void]$allBorders.Add($child) }
                    Collect-Borders $child
                }
            } catch {}
        }
        Collect-Borders $Window
        foreach ($b in $allBorders) {
            try {
                if ($b.Background -ne $null -and $b.Background.ToString() -like "*White*") {
                    $b.Background = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(22,33,62))
                }
            } catch {}
        }
        Write-Out "Dark mode ON" "INFO"
    } else {
        $btnDarkMode.Content = [char]0x263C  # sun = light mode active, click for dark
        $btnDarkMode.ToolTip = "Switch to Dark mode"
        $Window.Background = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(240,242,245))
        # Reload window resources to reset - simplest is to tell user to restart
        # For now just reset window bg and tab bg
        foreach ($ctrl in @($tabMain)) {
            try { $ctrl.Background = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(240,242,245)) } catch {}
        }
        Write-Out "Light mode ON (restart app for full reset)" "INFO"
    }
}
#endregion
#region ── EVENT WIRING ────────────────────────────────────────────────────────
$btnRefreshSystem.Add_Click({ Load-SystemInfo })
$btnRefreshDomain.Add_Click({ Load-DomainInfo })

$btnLoadOUs.Add_Click({ Load-OUTree -Filter $txtOUFilter.Text.Trim() })
$txtOUFilter.Add_KeyDown({ param($s,$e); if ($e.Key -eq "Return") { Load-OUTree -Filter $txtOUFilter.Text.Trim() } })
$btnExportOUsBtn.Add_Click({
    if (-not $Script:CachedOUs) { Show-Err "Load OUs first."; return }
    $path = Pick-SavePath -Default "AD_OUs.csv"; if (-not $path) { return }
    try { $Script:CachedOUs | Select-Object Name,CanonicalName,Description,DistinguishedName | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8; Show-Info "Exported to:`n$path" } catch { Show-Err $_.Exception.Message }
})

$btnLoadShares.Add_Click({ Load-Shares })
$Script:SelectedSharePath = ""
$Script:SelectedShareName = ""
$gridShares.Add_SelectionChanged({
    if ($Script:LoadingShares) { return }
    $sel = $gridShares.SelectedItem
    if (-not $sel -or [string]::IsNullOrWhiteSpace($sel.Path)) { return }
    $path = $sel.Path
    $Script:SelectedSharePath = $path
    $Script:SelectedShareName = $sel.Name
    Set-Status "Share: $($sel.Name)  ->  $path  |  Showing ACL. Enter user/group + Check NTFS for deep scan." 0
    # Show share root ACL immediately in the bottom grid
    if (-not (Test-Path $path -ErrorAction SilentlyContinue)) {
        $gridPerms.ItemsSource = [object[]]@([PSCustomObject]@{ShareName=$sel.Name;FolderPath=$path;Principal="(path not accessible)";AccessType="--";Rights="--";Inherited="--";Source="Share root"})
        return
    }
    try {
        $acl = Get-Acl -Path $path -ErrorAction Stop
        $rows = @($acl.Access | ForEach-Object {
            [PSCustomObject]@{
                ShareName  = $sel.Name
                FolderPath = $path
                Principal  = $_.IdentityReference.Value
                AccessType = $_.AccessControlType
                Rights     = $_.FileSystemRights
                Inherited  = $_.IsInherited
                Source     = "Share root ACL"
            }
        })
        if ($rows.Count -eq 0) { $rows = @([PSCustomObject]@{ShareName=$sel.Name;FolderPath=$path;Principal="(no ACEs)";AccessType="--";Rights="--";Inherited="--";Source="Share root"}) }
        $gridPerms.ItemsSource = [object[]]@($rows)
        $Script:CachedPermsCheck = $rows
        Set-Status "Share: $($sel.Name) - $($rows.Count) ACEs on root. Enter user/group + Check NTFS for deep scan." 100
    } catch {
        $gridPerms.ItemsSource = [object[]]@([PSCustomObject]@{ShareName=$sel.Name;FolderPath=$path;Principal="Error: $($_.Exception.Message)";AccessType="--";Rights="--";Inherited="--";Source="Share root"})
    }
})
$btnPickUsers.Add_Click({
    $picks = Show-ADPickerDialog -Title "Pick User(s) from AD" -Mode "Users"
    if ($picks -and $picks.Count -gt 0) { $txtCheckUser.Text = $picks -join ";" }
})
$btnPickGroups.Add_Click({
    $picks = Show-ADPickerDialog -Title "Pick Group(s) from AD" -Mode "Groups"
    if ($picks -and $picks.Count -gt 0) { $txtCheckUser.Text = $picks -join ";" }
})
$btnBrowseFolder.Add_Click({
    $depth = 2
    if ($null -ne $txtScanDepth) { [int]::TryParse($txtScanDepth.Text.Trim(), [ref]$depth) | Out-Null }
    Scan-FolderPermissions -Identity $txtCheckUser.Text.Trim() -ScanDepth $depth
})
$btnCheckPerms.Add_Click({
    # Safety reset UI state before each scan
    $btnStopScan.Visibility  = [System.Windows.Visibility]::Collapsed
    $btnStopScan.IsEnabled   = $true
    $btnCheckPerms.IsEnabled = $true
    $Script:ScanCancelFlag   = $false
    if ($Script:ScanCancel) { $Script:ScanCancel.Value = $false }
    $depth = 2
    if ($null -ne $txtScanDepth) { [int]::TryParse($txtScanDepth.Text.Trim(), [ref]$depth) | Out-Null }
    $identity = $txtCheckUser.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($identity)) { Show-Info "Enter a username or group name first."; return }
    # If a share is selected in the top grid, scan only that path
    if (-not [string]::IsNullOrWhiteSpace($Script:SelectedSharePath)) {
        $skipSys = ($chkSkipSystemFolders.IsChecked -eq $true)
        Write-OutputCmd "Get-NTFSPermissionsRecursive -Path '$($Script:SelectedSharePath)' -Identity '$identity' -Depth $depth"
        Set-Status "Scanning '$($Script:SelectedSharePath)' for '$identity'..." 5
        $results = Get-NTFSPermissionsRecursive -Path $Script:SelectedSharePath -Identity $identity -ShareName $gridShares.SelectedItem.Name -MaxDepth $depth
        if ($results.Count -eq 0) {
            $results = @([PSCustomObject]@{ShareName=$gridShares.SelectedItem.Name;FolderPath=$Script:SelectedSharePath;Principal=$identity;AccessType="No explicit permissions found";Rights="--";Inherited="--";Source="--"})
        }
        $Script:CachedPermsCheck = $results
        $gridPerms.ItemsSource = [object[]]@($results)
        Set-Status "Done. $($results.Count) entries found in selected share." 100
    } else {
        $skipSys   = ($chkSkipSystemFolders.IsChecked -eq $true)
        $skipAdmin = ($chkSkipAdminShares.IsChecked   -eq $true)
        $limitRes  = ($chkLimitResults.IsChecked      -eq $true)
        Check-UserSharePermissions -Identity $identity -ScanDepth $depth `
            -SkipSystemFolders $skipSys -SkipAdminShares $skipAdmin -LimitResults $limitRes
    }
})
$btnStopScan.Add_Click({
    $Script:ScanCancelFlag = $true
    $Script:ScanCancel.Value = $true
    try{"stop"|Set-Content "$env:TEMP\ADMgr_StopScan.tmp" -EA SilentlyContinue}catch{}
    $btnStopScan.IsEnabled = $false
    Set-Status "Διακοπή scan... περιμένετε να ολοκληρωθεί το τρέχον share." 0
})
$txtCheckUser.Add_KeyDown({ param($s,$e); if ($e.Key -eq "Return") { Check-UserSharePermissions -Identity $txtCheckUser.Text.Trim() } })
$btnExportSharesBtn.Add_Click({ Export-ToCSV -Data $Script:CachedShares -DefaultName "AD_Shares.csv" })
$btnExportPermsBtn.Add_Click({
    if (-not $Script:CachedShares) { Load-Shares }
    Set-Status "Collecting full NTFS permissions..." 5
    $allPerms = [System.Collections.Generic.List[object]]::new()
    foreach ($share in $Script:CachedShares) {
        if ([string]::IsNullOrWhiteSpace($share.Path) -or -not (Test-Path $share.Path -ErrorAction SilentlyContinue)) { continue }
        try {
            $acl = Get-Acl -Path $share.Path -ErrorAction Stop
            foreach ($ace in $acl.Access) {
                $allPerms.Add([PSCustomObject]@{ShareName=$share.Name;SharePath=$share.Path;Principal=$ace.IdentityReference.Value;AccessType=$ace.AccessControlType;Rights=$ace.FileSystemRights;Inherited=$ace.IsInherited})
            }
        } catch { }
    }
    Export-ToCSV -Data $allPerms -DefaultName "AD_SharePermissions.csv"
})
$btnExportPermsResult.Add_Click({ Export-ToCSV -Data $Script:CachedPermsCheck -DefaultName "AD_PermCheck.csv" })

$btnLoadUsers.Add_Click({ Load-ADUsers -Filter $txtUserFilter.Text.Trim() -DisabledOnly ($chkDisabledUsers.IsChecked -eq $true) })
$txtUserFilter.Add_KeyDown({ param($s,$e); if ($e.Key -eq "Return") { Load-ADUsers -Filter $txtUserFilter.Text.Trim() -DisabledOnly ($chkDisabledUsers.IsChecked -eq $true) } })
$btnExportUsersBtn.Add_Click({ Export-ToCSV -Data $Script:CachedUsers -DefaultName "AD_Users.csv" })

# ── USER AUTH AUDIT ────────────────────────────────────────────────────────────
function Show-UserAuthAudit {
    $sel = $gridUsers.SelectedItem
    if (-not $sel) { Show-Info "Select a user from the list first."; return }
    $username = $sel.Username
    if (-not $username) { Show-Info "Could not determine username."; return }

    [xml]$auditXaml = [xml]([string]@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Auth Audit" Width="1100" Height="640" MinWidth="700" MinHeight="440"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize" Background="#F8F9FA">
  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock Grid.Row="0" Text="Authentication Audit - $username" FontSize="16" FontWeight="Bold" Foreground="#1E3A5F" Margin="0,0,0,8"/>
    <!-- Audit prerequisite notice -->
    <Border Grid.Row="1" Background="#FFF8E1" BorderBrush="#F9A825" BorderThickness="1" CornerRadius="4" Padding="10,8" Margin="0,0,0,8">
      <StackPanel>
        <TextBlock TextWrapping="Wrap" FontSize="11" Foreground="#5D4037">
          <Run FontWeight="Bold">Requirement: </Run>
          <Run>Audit policies must be enabled in Group Policy for events to be recorded on DCs.</Run>
        </TextBlock>
        <TextBlock TextWrapping="Wrap" FontSize="11" Foreground="#5D4037" Margin="0,4,0,0"
                   Text="Required: Computer Config -> Windows Settings -> Security Settings -> Advanced Audit Policy -> Account Logon (enable: Kerberos Authentication Service, Credential Validation) and Logon/Logoff (enable: Logon, Account Lockout)."/>
        <TextBlock TextWrapping="Wrap" FontSize="11" Foreground="#5D4037" Margin="0,4,0,0"
                   Text="Also check: File > Settings > Audit Policies tab to verify and apply audit settings."/>
      </StackPanel>
    </Border>
    <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,0,0,8">
      <TextBlock Text="Days back:" VerticalAlignment="Center" Margin="0,0,6,0" FontSize="12"/>
      <TextBox x:Name="txtAuditDays" Width="50" Height="26" Text="7" FontSize="12" VerticalContentAlignment="Center" Padding="4,0" Margin="0,0,12,0"/>
      <Button x:Name="btnRunAudit" Content="Run Audit" Width="100" Height="28" Background="#1E6EB5" Foreground="White" BorderThickness="0" FontWeight="SemiBold" Cursor="Hand" Margin="0,0,8,0"/>
      <Button x:Name="btnStopAudit" Content="Stop" Width="70" Height="28" Background="#E74C3C" Foreground="White" BorderThickness="0" FontWeight="SemiBold" Cursor="Hand" Visibility="Collapsed"/>
      <TextBlock x:Name="lblAuditStatus" Text="Select days and click Run Audit" FontSize="11" Foreground="#555" VerticalAlignment="Center" Margin="12,0,0,0" TextWrapping="Wrap"/>
    </StackPanel>
    <Border Grid.Row="3" BorderBrush="#DDE1E7" BorderThickness="1" CornerRadius="4">
      <DataGrid x:Name="gridAuditDlg" AutoGenerateColumns="True" IsReadOnly="True"
                GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#EEEEEE"
                RowBackground="White" AlternatingRowBackground="#F8F9FA"
                CanUserSortColumns="True" CanUserResizeColumns="True"
                HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Auto" FontSize="11"/>
    </Border>
    <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
      <Button x:Name="btnAuditExport" Content="Export CSV" Width="100" Height="28" Background="#27AE60" Foreground="White" BorderThickness="0" FontWeight="SemiBold" Cursor="Hand" Margin="0,0,8,0"/>
      <Button x:Name="btnAuditClose" Content="Close" Width="80" Height="28" Background="#555" Foreground="White" BorderThickness="0" FontWeight="SemiBold" Cursor="Hand"/>
    </StackPanel>
  </Grid>
</Window>
'@)
    $auditR = [System.Xml.XmlNodeReader]::new($auditXaml)
    $auditW = [Windows.Markup.XamlReader]::Load($auditR)
    $auditW.Owner = $Window
    $auditW.Title = "Auth Audit - $username"

    $aGrid  = $auditW.FindName("gridAuditDlg")
    $aDays  = $auditW.FindName("txtAuditDays")
    $aBtn   = $auditW.FindName("btnRunAudit")
    $aStop  = $auditW.FindName("btnStopAudit")
    $aLbl   = $auditW.FindName("lblAuditStatus")
    $aExp   = $auditW.FindName("btnAuditExport")
    $aClose = $auditW.FindName("btnAuditClose")
    $aGrid.Add_Sorting($Script:SortHandler)
    $Script:AuditResults = @()
    $Script:AuditCancel = $false

    $aBtn.Add_Click({
        $Script:AuditCancel = $false
        $aBtn.IsEnabled = $false
        $aStop.Visibility = [System.Windows.Visibility]::Visible
        $days = 7; [int]::TryParse($aDays.Text.Trim(),[ref]$days)|Out-Null
        $days = [math]::Max(1,[math]::Min($days,90))
        $aLbl.Text = "Starting audit for $username, last $days days..."
        $aGrid.ItemsSource = $null

        # Capture for runspace
        $__lbl=$aLbl; $__grid=$aGrid; $__btn=$aBtn; $__stop=$aStop
        $__user=$username; $__days=$days; $__cancelRef=[ref]$Script:AuditCancel

        $auditStr = @'
param($lbl,$grid,$btn,$stop,$user,$days,$cancelRef)
function ui{param($c,$sb)try{$c.Dispatcher.Invoke([System.Action]$sb)}catch{}}
$startTime=(Get-Date).AddDays(-$days)
$eventIds=@(4624,4625,4768,4769,4771,4776,4740)
$results=[System.Collections.Generic.List[object]]::new()
try{$dcs=Get-ADDomainController -Filter * | Sort-Object HostName}catch{$dcs=@()}
$total=$dcs.Count;$idx=0
foreach($dc in $dcs){
    if($cancelRef.Value){break}
    $idx++
    ui $lbl {$lbl.Text="Querying DC $idx/$($total): $($dc.HostName)..."}
    try{
        $events=Get-WinEvent -ComputerName $dc.HostName -FilterHashtable @{LogName='Security';ID=$eventIds;StartTime=$startTime} -ErrorAction Stop
        foreach($ev in $events){
            if($cancelRef.Value){break}
            try{
                $xml=[xml]$ev.ToXml();$data=@{}
                foreach($item in $xml.Event.EventData.Data){$data[$item.Name]=$item.'#text'}
                $acc=$null;$matched=$false;$status='';$desc='';$src='';$ws='';$auth='';$lt=''
                switch($ev.Id){
                    4624{$acc=$data.TargetUserName;if($acc -ieq $user){$matched=$true;$status='Logon OK';$desc='Successful logon';$src=$data.IpAddress;$ws=$data.WorkstationName;$auth=$data.AuthenticationPackageName;$lt=$data.LogonType}}
                    4625{$acc=$data.TargetUserName;if($acc -ieq $user){$matched=$true;$status='Logon FAIL';$desc='Failed logon';$src=$data.IpAddress;$ws=$data.WorkstationName;$auth=$data.AuthenticationPackageName;$lt=$data.LogonType}}
                    4768{$acc=$data.TargetUserName;if($acc -ieq $user){$matched=$true;$status='Kerberos TGT';$desc='Kerberos initial auth';$src=$data.IpAddress;$ws=$data.WorkstationName;$auth='Kerberos'}}
                    4769{$acc=$data.TargetUserName;if($acc -ieq $user){$matched=$true;$status='Kerberos Svc';$desc='Kerberos service ticket';$src=$data.IpAddress;$ws=$data.ServiceName;$auth='Kerberos'}}
                    4771{$acc=$data.TargetUserName;if($acc -ieq $user){$matched=$true;$status='Kerberos FAIL';$desc='Kerberos pre-auth failed';$src=$data.IpAddress;$ws=$data.WorkstationName;$auth='Kerberos'}}
                    4776{$acc=$data.TargetUserName;if($acc -ieq $user){$matched=$true;$status='NTLM';$desc='NTLM authentication';$src=$data.Workstation;$ws=$data.Workstation;$auth='NTLM'}}
                    4740{$acc=$data.TargetUserName;if($acc -ieq $user){$matched=$true;$status='LOCKED OUT';$desc='Account lockout';$src=$data.CallerComputerName;$ws=$data.CallerComputerName}}
                }
                if($matched){
                    $ltTxt=switch($lt){'2'{'Interactive/Console'}'3'{'Network'}'4'{'Batch'}'5'{'Service'}'7'{'Unlock'}'8'{'ClearText'}'10'{'RDP'}'11'{'CachedInteractive'}default{$lt}}
                    [void]$results.Add([PSCustomObject]@{Time=$ev.TimeCreated;DC=$dc.HostName;EventID=$ev.Id;Status=$status;Description=$desc;Source=$src;Workstation=$ws;LogonType=$ltTxt;AuthPackage=$auth})
                }
            }catch{}
        }
    }catch{[void]$results.Add([PSCustomObject]@{Time=(Get-Date);DC=$dc.HostName;EventID=0;Status='DC ERROR';Description=$_.Exception.Message;Source='';Workstation='';LogonType='';AuthPackage=''})}
    $snap=[object[]]@($results|Sort-Object Time -Descending)
    ui $grid {$grid.ItemsSource=$snap}
}
$all=[object[]]@($results|Sort-Object Time -Descending)
ui $grid {$grid.ItemsSource=$all}
$msg=if($cancelRef.Value){"Stopped. Found $($results.Count) events."}elseif($results.Count -eq 0){"No events found. Verify Audit policies are enabled in GPO (see yellow notice above)."}else{"Done. Found $($results.Count) events for $user."}
ui $lbl  {$lbl.Text=$msg}
ui $btn  {$btn.IsEnabled=$true}
ui $stop {$stop.Visibility=[System.Windows.Visibility]::Collapsed}
'@
        $rs=[System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $rs.ApartmentState='STA';$rs.ThreadOptions='ReuseThread';$rs.Open()
        $ps=[System.Management.Automation.PowerShell]::Create()
        $ps.Runspace=$rs
        [void]$ps.AddScript([scriptblock]::Create($auditStr)).AddArgument($__lbl).AddArgument($__grid).AddArgument($__btn).AddArgument($__stop).AddArgument($__user).AddArgument($__days).AddArgument($__cancelRef)
        $handle=$ps.BeginInvoke()
        $tmr=New-Object System.Windows.Threading.DispatcherTimer
        $tmr.Interval=[TimeSpan]::FromMilliseconds(500)
        $tmr.Add_Tick({
            if($handle.IsCompleted){
                $tmr.Stop()
                try{$ps.EndInvoke($handle)}catch{}
                $ps.Dispose();$rs.Dispose()
            }
        })
        $tmr.Start()
    })

    $aStop.Add_Click({ $Script:AuditCancel = $true; $aStop.IsEnabled = $false })
    $aExp.Add_Click({
        $d = $aGrid.ItemsSource
        if (-not $d -or @($d).Count -eq 0) { Show-Info "No results to export."; return }
        $safeUser = $username -replace '[\\/:*?"<>|]','_'
        Export-ToCSV -Data @($d) -DefaultName "AuthAudit_$safeUser.csv"
    })
    $aClose.Add_Click({ $Script:AuditCancel = $true; $auditW.Close() })
    $auditW.ShowDialog() | Out-Null
}

$btnUserAudit.Add_Click({ Show-UserAuthAudit })
$btnEnableSelected.Add_Click({ Set-SelectedAccountState -Enable $true })
$btnResetPassword.Add_Click({
    $sel = $gridUsers.SelectedItem
    if (-not $sel) { Show-Err "Select a user first."; return }
    $r = [System.Windows.MessageBox]::Show("Reset password for:`n$($sel.DisplayName) ($($sel.Username))?", "Confirm Reset Password", "YesNo", "Warning")
    if ($r -eq "Yes") { Reset-SelectedPassword }
})
$btnUnlockAccount.Add_Click({ Unlock-SelectedAccount })
$btnLoadHeatmap.Add_Click({ Load-LastLogonHeatmap })
$btnHeatmapDetailClose.Add_Click({ $borderHeatmapDetail.Visibility = [System.Windows.Visibility]::Collapsed })
$btnUsersHeatmapDetailClose.Add_Click({ $borderUsersHeatmapDetail.Visibility = [System.Windows.Visibility]::Collapsed })
$btnLoadStale.Add_Click({
    $d = 30; [int]::TryParse($txtStaleDays.Text.Trim(), [ref]$d) | Out-Null
    Load-StaleComputers -Days $d
})
$btnExportStale.Add_Click({ Export-ToCSV -Data $Script:CachedStale -DefaultName "AD_StaleComputers.csv" })
$btnPickDiffA.Add_Click({ $p = Show-UserPickerDialog; if ($p) { $txtDiffUserA.Text = $p } })
$btnPickDiffB.Add_Click({ $p = Show-UserPickerDialog; if ($p) { $txtDiffUserB.Text = $p } })
$btnRunDiff.Add_Click({ Run-GroupDiff -UserA $txtDiffUserA.Text.Trim() -UserB $txtDiffUserB.Text.Trim() })
$btnExportDiff.Add_Click({ Export-ToCSV -Data $Script:CachedGroupDiff -DefaultName "AD_GroupDiff.csv" })
$btnRunHealth.Add_Click({ Run-ADHealthCheck })
$btnExportHealth.Add_Click({ Export-ToCSV -Data $Script:CachedHealth -DefaultName "AD_HealthCheck.csv" })
$btnDarkMode.Add_Click({ Toggle-DarkMode })
$btnDisableSelected_REPLACED = $null  # handler moved to new section with confirmation
$btnMemberOf.Add_Click({
    $sel = $gridUsers.SelectedItem
    if (-not $sel) { Show-Err "Select a user in the grid first."; return }
    Load-MemberOf -Username $sel.Username
})

$btnLoadGroups.Add_Click({ Load-ADGroups -Filter $txtGroupFilter.Text.Trim() -IncludeNested ($chkNestedMembers.IsChecked -eq $true) })
$txtGroupFilter.Add_KeyDown({ param($s,$e); if ($e.Key -eq "Return") { Load-ADGroups -Filter $txtGroupFilter.Text.Trim() -IncludeNested ($chkNestedMembers.IsChecked -eq $true) } })
$btnExportGroupsBtn.Add_Click({ Export-ToCSV -Data $Script:CachedGroups -DefaultName "AD_Groups.csv" })
$ctxGroupDetails.Add_Click({ Show-GroupDetails })
$gridGroups.Add_MouseDoubleClick({ param($s,$e) if($gridGroups.SelectedItem){ Show-GroupDetails } })

function Show-GroupDetails {
    $sel = $gridGroups.SelectedItem
    if (-not $sel) { Show-Err "Select a group first."; return }
    if (-not (Ensure-ADModule)) { return }
    try {
        $g = Get-ADGroup -Identity $sel.SAMAccount -Properties * -ErrorAction Stop
        $members = @(Get-ADGroupMember -Identity $g -ErrorAction Stop | Sort-Object Name)
        $Script:GroupDetailObj  = $g
        $Script:GroupDetailMembers = $members

        [xml]$gdXml = [xml]([string]@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Group Details" Width="900" Height="640" MinWidth="700" MinHeight="500"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize" Background="#F8F9FA">
  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock Grid.Row="0" x:Name="lblGrpTitle" FontSize="15" FontWeight="Bold" Foreground="#1E3A5F" Margin="0,0,0,10"/>
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="280"/>
        <ColumnDefinition Width="4"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <!-- Left: Group Info -->
      <Border Grid.Column="0" BorderBrush="#DDE1E7" BorderThickness="1" CornerRadius="4">
        <TextBox x:Name="txtGrpDetail" IsReadOnly="True" FontFamily="Consolas" FontSize="11"
                 TextWrapping="Wrap" AcceptsReturn="True" VerticalScrollBarVisibility="Auto"
                 Background="#1a1a2e" Foreground="#00e676" Padding="10" BorderThickness="0"/>
      </Border>
      <GridSplitter Grid.Column="1" Width="4" HorizontalAlignment="Center" VerticalAlignment="Stretch" Background="#CCD3DC" ShowsPreview="True"/>
      <!-- Right: Members -->
      <Grid Grid.Column="2">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" x:Name="lblMembersCount" Text="Members" FontSize="12" FontWeight="SemiBold" Foreground="#1E3A5F" Margin="4,0,0,6"/>
        <Border Grid.Row="1" BorderBrush="#DDE1E7" BorderThickness="1" CornerRadius="4">
          <ListBox x:Name="lstMembers" FontSize="12" BorderThickness="0"
                   SelectionMode="Extended" ToolTip="Ctrl+Click or Shift+Click for multiple selection"/>
        </Border>
        <!-- Add member -->
        <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,8,0,4">
          <TextBox x:Name="txtAddMember" Width="160" Height="26" FontSize="11"
                   VerticalContentAlignment="Center" Padding="6,0" BorderBrush="#CCC" BorderThickness="1"
                   ToolTip="Type username (SAMAccountName) then click Add, or Browse"/>
          <Button x:Name="btnBrowseMember" Content="Browse..." Width="75" Height="26"
                  BorderBrush="#555" BorderThickness="1" FontSize="11" Cursor="Hand" Margin="4,0,0,0"
                  ToolTip="Search AD users to add"/>
          <Button x:Name="btnAddMember" Content="Add" Width="55" Height="26"
                  Background="#27AE60" Foreground="White" BorderThickness="0"
                  FontWeight="SemiBold" Cursor="Hand" Margin="4,0,0,0"/>
        </StackPanel>
        <Button Grid.Row="3" x:Name="btnRemoveMember" Content="Remove Selected Members"
                Height="28" Background="#E74C3C" Foreground="White" BorderThickness="0"
                FontWeight="SemiBold" Cursor="Hand" ToolTip="Remove selected members from this group"/>
      </Grid>
    </Grid>
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
      <Button x:Name="btnGrpCopy"  Content="Copy Info" Width="90" Height="28" Background="#1E6EB5" Foreground="White" BorderThickness="0" FontWeight="SemiBold" Cursor="Hand" Margin="0,0,8,0"/>
      <Button x:Name="btnGrpClose" Content="Close" Width="80" Height="28" BorderBrush="#CCC" BorderThickness="1" Cursor="Hand"/>
    </StackPanel>
  </Grid>
</Window>
'@)
        $gdR = [System.Xml.XmlNodeReader]::new($gdXml)
        $gdW = [Windows.Markup.XamlReader]::Load($gdR)
        $gdW.Owner = $Window

        $lblTitle    = $gdW.FindName("lblGrpTitle")
        $txtDet      = $gdW.FindName("txtGrpDetail")
        $lstMbrs     = $gdW.FindName("lstMembers")
        $lblMbrCnt   = $gdW.FindName("lblMembersCount")
        $txtAddMbr   = $gdW.FindName("txtAddMember")
        $btnBrowseMbr= $gdW.FindName("btnBrowseMember")
        $btnAddMbr   = $gdW.FindName("btnAddMember")
        $btnRemoveMbr= $gdW.FindName("btnRemoveMember")

        $Script:GdW = $gdW; $Script:GdLstMbrs = $lstMbrs; $Script:GdLblCnt = $lblMbrCnt
        $Script:GdTxtAddMbr = $txtAddMbr

        $lblTitle.Text = "Group: $($g.Name)  ($($g.GroupCategory) / $($g.GroupScope))"

        # Build info text
        $info  = "Name        : $($g.Name)`n"
        $info += "SAMAccount  : $($g.SamAccountName)`n"
        $info += "Category    : $($g.GroupCategory)`n"
        $info += "Scope       : $($g.GroupScope)`n"
        $info += "Description : $($g.Description)`n"
        $info += "Email       : $($g.mail)`n"
        $mgr = if($g.ManagedBy){($g.ManagedBy -split ',')[0] -replace '^CN=',''}else{''}
        $info += "ManagedBy   : $mgr`n"
        $info += "Created     : $($g.WhenCreated)`n"
        $info += "Modified    : $($g.WhenChanged)`n"
        $info += "Members     : $($members.Count)`n"
        $info += "DN          : $($g.DistinguishedName)"
        $txtDet.Text = $info

        # Populate members
        $lstMbrs.Items.Clear()
        foreach ($m in $members) { [void]$lstMbrs.Items.Add("$($m.Name)  [$($m.objectClass)]") }
        $lblMbrCnt.Text = "Members ($($members.Count)) - Ctrl+Click for multi-select"

        # Browse users to add
        $btnBrowseMbr.Add_Click({
            [xml]$bXml = [xml]([string]@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Browse Users/Groups" Width="500" Height="420" MinWidth="380" MinHeight="320"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize" Background="#F8F9FA">
  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,8">
      <TextBox x:Name="txtMbrSearch" Width="280" Height="28" FontSize="12" VerticalContentAlignment="Center" Padding="6,0" BorderBrush="#CCC" BorderThickness="1" ToolTip="Search users or groups by name"/>
      <Button x:Name="btnMbrSearch" Content="Search" Width="80" Height="28" Background="#1E6EB5" Foreground="White" BorderThickness="0" FontWeight="SemiBold" Cursor="Hand" Margin="6,0,0,0"/>
    </StackPanel>
    <ListBox x:Name="lstMbrResults" Grid.Row="1" FontSize="12" BorderBrush="#DDE1E7" BorderThickness="1" SelectionMode="Extended" ToolTip="Ctrl+Click or Shift+Click for multiple"/>
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
      <Button x:Name="btnMbrSelect" Content="Add Selected" Width="100" Height="28" Background="#27AE60" Foreground="White" BorderThickness="0" FontWeight="SemiBold" Cursor="Hand" Margin="0,0,8,0"/>
      <Button x:Name="btnMbrCancel" Content="Cancel" Width="80" Height="28" BorderBrush="#CCC" BorderThickness="1" Cursor="Hand"/>
    </StackPanel>
  </Grid>
</Window>
'@)
            $bR2 = [System.Xml.XmlNodeReader]::new($bXml)
            $bW2 = [Windows.Markup.XamlReader]::Load($bR2)
            $bW2.Owner = $gdW
            $bSrch = $bW2.FindName("txtMbrSearch")
            $bLst  = $bW2.FindName("lstMbrResults")
            $Script:MbrSearchCtrl = $bSrch; $Script:MbrListCtrl = $bLst
            # Load all users on open
            $Script:MbrDoSearch = {
                $q = $Script:MbrSearchCtrl.Text.Trim()
                $Script:MbrListCtrl.Items.Clear()
                try {
                    $filter = if ($q) { "SamAccountName -like '*$q*' -or Name -like '*$q*'" } else { "Name -like '*'" }
                    $users = Get-ADUser -Filter $filter -ResultSetSize 200 -EA Stop | Sort-Object SamAccountName
                    foreach ($u2 in $users) { [void]$Script:MbrListCtrl.Items.Add("$($u2.SamAccountName)  ($($u2.Name))") }
                    $groups2 = Get-ADGroup -Filter $filter -ResultSetSize 100 -EA Stop | Sort-Object Name
                    foreach ($g2 in $groups2) { [void]$Script:MbrListCtrl.Items.Add("$($g2.SamAccountName)  [Group]") }
                } catch { [void]$Script:MbrListCtrl.Items.Add("Error: $($_.Exception.Message)") }
            }
            & $Script:MbrDoSearch
            $bSrch.Add_KeyDown({ param($s,$e) if($e.Key -eq "Return"){ & $Script:MbrDoSearch } })
            $bW2.FindName("btnMbrSearch").Add_Click({ & $Script:MbrDoSearch })
            $bW2.FindName("btnMbrSelect").Add_Click({
                $selected = @($bLst.SelectedItems | Where-Object { $_ -notlike '*Error*' })
                if ($selected.Count -eq 0) { return }
                foreach ($item in $selected) {
                    $sam = ($item -split '\s+')[0]
                    try {
                        Add-ADGroupMember -Identity $Script:GroupDetailObj.SamAccountName -Members $sam -EA Stop
                        if (-not ($Script:GdLstMbrs.Items | Where-Object { $_ -like "$sam *" })) {
                            [void]$Script:GdLstMbrs.Items.Add("$sam  [added]")
                        }
                    } catch { [System.Windows.MessageBox]::Show("Error adding $sam`: $($_.Exception.Message)","Error","OK","Error")|Out-Null }
                }
                $Script:GdLblCnt.Text = "Members ($($Script:GdLstMbrs.Items.Count)) - Ctrl+Click for multi-select"
                $bW2.Close()
            })
            $bW2.FindName("btnMbrCancel").Add_Click({ $bW2.Close() })
            $bW2.ShowDialog() | Out-Null
        })

        # Add member manually
        $btnAddMbr.Add_Click({
            $sam = $Script:GdTxtAddMbr.Text.Trim()
            if (-not $sam) { return }
            try {
                Add-ADGroupMember -Identity $Script:GroupDetailObj.SamAccountName -Members $sam -EA Stop
                if (-not ($Script:GdLstMbrs.Items | Where-Object { $_ -like "$sam *" })) {
                    [void]$Script:GdLstMbrs.Items.Add("$sam  [added]")
                }
                $Script:GdTxtAddMbr.Text = ""
                $Script:GdLblCnt.Text = "Members ($($Script:GdLstMbrs.Items.Count))"
            } catch { [System.Windows.MessageBox]::Show("Error: $($_.Exception.Message)","Error","OK","Error")|Out-Null }
        })

        # Remove members
        $btnRemoveMbr.Add_Click({
            $selected = @($Script:GdLstMbrs.SelectedItems)
            if ($selected.Count -eq 0) { [System.Windows.MessageBox]::Show("Select members to remove.","Info","OK","Information")|Out-Null; return }
            $confirm = [System.Windows.MessageBox]::Show("Remove $($selected.Count) member(s) from $($Script:GroupDetailObj.Name)?","Confirm","YesNo","Warning")
            if ($confirm -ne "Yes") { return }
            foreach ($item in $selected) {
                $sam = ($item -split '\s+')[0]
                try {
                    Remove-ADGroupMember -Identity $Script:GroupDetailObj.SamAccountName -Members $sam -Confirm:$false -EA Stop
                    [void]$lstMbrs.Items.Remove($item)
                } catch { [System.Windows.MessageBox]::Show("Error removing $sam`: $($_.Exception.Message)","Error","OK","Error")|Out-Null }
            }
            $lblMbrCnt.Text = "Members ($($lstMbrs.Items.Count))"
        })

        $gdW.FindName("btnGrpCopy").Add_Click({ [System.Windows.Clipboard]::SetText($info) })
        $gdW.FindName("btnGrpClose").Add_Click({ $gdW.Close() })
        $gdW.ShowDialog() | Out-Null
    } catch { Show-Err "Error: $($_.Exception.Message)" }
}

$btnLoadComputers.Add_Click({ Load-ADComputers -Filter $txtComputerFilter.Text.Trim() })
$txtComputerFilter.Add_KeyDown({ param($s,$e); if ($e.Key -eq "Return") { Load-ADComputers -Filter $txtComputerFilter.Text.Trim() } })
$btnExportComputersBtn.Add_Click({ Export-ToCSV -Data $Script:CachedComputers -DefaultName "AD_Computers.csv" })

$btnLoadGPOs.Add_Click({ Load-GPOs })
$btnExportGPOsBtn.Add_Click({ Export-ToCSV -Data $gridGPOs.ItemsSource -DefaultName "AD_GPOs.csv" })
$btnLoadGPOLinks.Add_Click({ Load-GPOLinks })

$btnPwdExpiry.Add_Click({ $d=30; [int]::TryParse($txtPwdDays.Text.Trim(),[ref]$d)|Out-Null; Load-PasswordExpiry -Days $d })
$btnExportPwdExpiry.Add_Click({ Export-ToCSV -Data $Script:CachedPwdExpiry -DefaultName "AD_PwdExpiry.csv" })

$btnLoadInactive.Add_Click({ $d=90; [int]::TryParse($txtInactiveDays.Text.Trim(),[ref]$d)|Out-Null; Load-InactiveUsers -Days $d })
$btnLoadInactiveComp.Add_Click({ $d=90; [int]::TryParse($txtInactiveDays.Text.Trim(),[ref]$d)|Out-Null; Load-InactiveComputers -Days $d })
$btnExportInactive.Add_Click({ Export-ToCSV -Data $Script:CachedInactiveU -DefaultName "AD_InactiveUsers.csv" })

$btnLoadRecycleBin.Add_Click({ Load-RecycleBin })
$btnExportRecycleBin.Add_Click({ Export-ToCSV -Data $Script:CachedRecycleBin -DefaultName "AD_RecycleBin.csv" })

$btnLoadDNS.Add_Click({ Load-DNSZones })
$btnExportDNS.Add_Click({ Export-ToCSV -Data $Script:CachedDNSZones -DefaultName "AD_DNSZones.csv" })
$btnLoadDNSRec.Add_Click({ Load-DNSZoneRecords })

$btnLoadDHCP.Add_Click({ Load-DHCPScopes -Server $txtDhcpServer.Text.Trim() })
$btnExportDHCP.Add_Click({ Export-ToCSV -Data $Script:CachedDHCP -DefaultName "AD_DHCPScopes.csv" })
$btnLoadLeases.Add_Click({ Load-DHCPLeases })

$btnClearLog.Add_Click({ $Global:txtLog.Clear(); Write-ADLog "Log cleared." })
$btnClearOutput.Add_Click({ if ($null -ne $Global:txtOutput) { $Global:txtOutput.Clear() }; [void]$Script:OutputBuffer.Clear(); Write-ADLog "Output cleared." })
$saveOutputAction = {
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = "Text files (*.txt)|*.txt|All files (*.*)|*.*"; $dlg.FileName = "AD_Manager_Output.txt"
    if ($dlg.ShowDialog() -eq "OK") {
        try {
            [System.IO.File]::WriteAllText($dlg.FileName, $Script:OutputBuffer.ToString())
            Write-ADLog "Output saved to: $($dlg.FileName)"; Show-Info "Output saved to:`n$($dlg.FileName)"
        } catch { Show-Err "Save failed: $($_.Exception.Message)" }
    }
}
$btnSaveOutputBtn.Add_Click($saveOutputAction)
$menuClearLog.Add_Click({ $Global:txtLog.Clear(); Write-ADLog "Log cleared." })

$saveLogAction = {
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = "Text files (*.txt)|*.txt|All files (*.*)|*.*"; $dlg.FileName = "AD_Manager_Log.txt"
    if ($dlg.ShowDialog() -eq "OK") {
        try {
            [System.IO.File]::WriteAllText($dlg.FileName, $Script:LogBuffer.ToString())
            Write-ADLog "Log saved to: $($dlg.FileName)"; Show-Info "Log saved to:`n$($dlg.FileName)"
        } catch { Show-Err "Save failed: $($_.Exception.Message)" }
    }
}
$btnSaveLogBtn.Add_Click($saveLogAction)
$menuSaveLog.Add_Click($saveLogAction)
$menuExit.Add_Click({ $Window.Close() })
$menuRefreshAll.Add_Click({ Load-SystemInfo; Load-DomainInfo })
$menuExportUsers.Add_Click({ if (-not $Script:CachedUsers) { Load-ADUsers }; Export-ToCSV -Data $Script:CachedUsers -DefaultName "AD_Users.csv" })
$menuExportGroups.Add_Click({ if (-not $Script:CachedGroups) { Load-ADGroups }; Export-ToCSV -Data $Script:CachedGroups -DefaultName "AD_Groups.csv" })
$menuExportComputers.Add_Click({ if (-not $Script:CachedComputers) { Load-ADComputers }; Export-ToCSV -Data $Script:CachedComputers -DefaultName "AD_Computers.csv" })
$menuExportOUs.Add_Click({ if (-not $Script:CachedOUs) { Load-OUTree }; $path = Pick-SavePath -Default "AD_OUs.csv"; if ($path) { $Script:CachedOUs | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8; Show-Info "Exported to:`n$path" } })
$menuExportGPOs.Add_Click({ Export-ToCSV -Data $gridGPOs.ItemsSource -DefaultName "AD_GPOs.csv" })
$menuExportShares.Add_Click({ Export-ToCSV -Data $Script:CachedShares -DefaultName "AD_Shares.csv" })
$menuExportPerms.Add_Click({ Export-ToCSV -Data $Script:CachedPermsCheck -DefaultName "AD_PermCheck.csv" })
$menuHealth = B "menuHealth"; $menuDarkMode = B "menuDarkMode"
$menuHealth.Add_Click({ Run-ADHealthCheck })
$menuDarkMode.Add_Click({ Toggle-DarkMode })
$menuModules.Add_Click({
    $adOK = Get-Command Get-ADUser         -ErrorAction SilentlyContinue
    $gpOK = Get-Command Get-GPO            -ErrorAction SilentlyContinue
    $dnOK = Get-Command Get-DnsServerZone  -ErrorAction SilentlyContinue
    $dhOK = Get-Command Get-DhcpServerv4Scope -ErrorAction SilentlyContinue
    $adStr = if($adOK){'AVAILABLE'}else{'NOT FOUND (RSAT required)'}
    $gpStr = if($gpOK){'AVAILABLE'}else{'NOT FOUND (RSAT required)'}
    $dnStr = if($dnOK){'AVAILABLE'}else{'not found (optional)'}
    $dhStr = if($dhOK){'AVAILABLE'}else{'not found (optional)'}
    $msg  = "Module Status:`n"
    $msg += "  ActiveDirectory : $adStr`n"
    $msg += "  GroupPolicy     : $gpStr`n"
    $msg += "  DnsServer       : $dnStr`n"
    $msg += "  DhcpServer      : $dhStr"
    Show-Info $msg
})
$menuAbout.Add_Click({
    [xml]$aboutXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="About AD Manager" Width="600" Height="520" MinWidth="500" MinHeight="400"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize"
        Background="#F8F9FA">
  <Grid>
    <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto">
      <StackPanel Margin="30,24,30,10">
    <DockPanel Margin="0,0,0,4">
      <TextBlock Text="AD Manager" FontSize="22" FontWeight="Bold" Foreground="#1E3A5F"/>
      <TextBlock Text="v2.1" FontSize="13" Foreground="#888" VerticalAlignment="Bottom" Margin="8,0,0,4"/>
    </DockPanel>
    <TextBlock FontSize="12" Foreground="#555" Margin="0,0,0,14">
      <Run Text="All-in-one Active Directory Manager for Windows"/>
    </TextBlock>
    <TextBlock TextWrapping="Wrap" FontSize="11" Foreground="#444" Margin="0,0,0,10">
      <Run Text="Features: " FontWeight="SemiBold"/>
      <Run Text="User/Group/Computer management, NTFS permission scanner, GPO viewer, Password expiry, Inactive accounts, DNS Zones, DHCP, Last logon heatmap, Live filter, Excel export, OU Tree, AD Health check, Dark mode"/>
    </TextBlock>
    <TextBlock TextWrapping="Wrap" FontSize="11" Foreground="#444" Margin="0,0,0,10">
      <Run Text="Shortcuts: " FontWeight="SemiBold"/>
      <Run Text="F5 = Refresh current tab   Ctrl+E = Export   Ctrl+F = Focus filter"/>
    </TextBlock>
    <Separator Margin="0,0,0,14"/>
    <TextBlock FontSize="11" Foreground="#555" Margin="0,0,0,4">
      <Run Text="Author: " FontWeight="SemiBold"/><Run Text="Nikolaos Karanikolas"/>
    </TextBlock>
    <TextBlock FontSize="11" Margin="0,0,0,4">
      <Hyperlink x:Name="lnkSite" NavigateUri="https://karanik.gr"><Run Text="https://karanik.gr"/></Hyperlink>
    </TextBlock>
    <TextBlock FontSize="11" Margin="0,0,0,4">
      <Hyperlink x:Name="lnkGitHub" NavigateUri="https://github.com/karanikn"><Run Text="https://github.com/karanikn"/></Hyperlink>
    </TextBlock>
    <TextBlock FontSize="11" Foreground="#555" Margin="0,8,0,0">
      <Run Text="Requires: " FontWeight="SemiBold"/><Run Text="PowerShell 5.1+, RSAT (ActiveDirectory + GroupPolicy). DNS/DHCP modules optional."/>
    </TextBlock>
      </StackPanel>
    </ScrollViewer>
    <Button x:Name="btnAboutOK" Grid.Row="1" Content="OK" Width="80" Height="30"
            HorizontalAlignment="Right" Margin="30,8,30,16"
            Background="#1E6EB5" Foreground="White" BorderThickness="0"
            FontWeight="SemiBold" Cursor="Hand"/>
  </Grid>
</Window>
"@
    $aboutR = [System.Xml.XmlNodeReader]::new($aboutXaml)
    $aboutW = [Windows.Markup.XamlReader]::Load($aboutR)
    $aboutW.Owner = $Window
    $aboutW.FindName("lnkSite").Add_RequestNavigate({ param($s2,$e2) [System.Diagnostics.Process]::Start($e2.Uri.AbsoluteUri) | Out-Null; $e2.Handled = $true })
    $aboutW.FindName("lnkGitHub").Add_RequestNavigate({ param($s2,$e2) [System.Diagnostics.Process]::Start($e2.Uri.AbsoluteUri) | Out-Null; $e2.Handled = $true })
    $aboutW.FindName("btnAboutOK").Add_Click({ $aboutW.Close() })
    $aboutW.ShowDialog() | Out-Null
})

# ── SETTINGS DIALOG ──────────────────────────────────────────────────────────
$menuSettings.Add_Click({
    $setXml = [xml]([string]@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Settings" Width="780" Height="720" MinWidth="600" MinHeight="500"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize" Background="#F8F9FA">
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock Grid.Row="0" Text="Settings" FontSize="16" FontWeight="Bold" Foreground="#1E3A5F" Margin="0,0,0,12"/>
    <TabControl Grid.Row="1">
      <TabItem Header="General">
        <StackPanel Margin="16,12">
          <TextBlock Text="Keyboard Shortcuts" FontSize="12" FontWeight="SemiBold" Foreground="#1E3A5F" Margin="0,0,0,8"/>
          <Grid Margin="0,0,0,12">
            <Grid.ColumnDefinitions><ColumnDefinition Width="160"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Grid.RowDefinitions><RowDefinition Height="28"/><RowDefinition Height="28"/><RowDefinition Height="28"/></Grid.RowDefinitions>
            <TextBlock Grid.Row="0" Grid.Column="0" Text="Refresh current tab:" VerticalAlignment="Center" FontSize="11"/>
            <TextBox x:Name="txtShortcutRefresh" Grid.Row="0" Grid.Column="1" Text="F5" Height="24" Padding="6,0" FontSize="11" BorderBrush="#CCC" BorderThickness="1"/>
            <TextBlock Grid.Row="1" Grid.Column="0" Text="Export:" VerticalAlignment="Center" FontSize="11"/>
            <TextBox x:Name="txtShortcutExport"  Grid.Row="1" Grid.Column="1" Text="Ctrl+E" Height="24" Padding="6,0" FontSize="11" BorderBrush="#CCC" BorderThickness="1"/>
            <TextBlock Grid.Row="2" Grid.Column="0" Text="Focus filter:" VerticalAlignment="Center" FontSize="11"/>
            <TextBox x:Name="txtShortcutFilter"  Grid.Row="2" Grid.Column="1" Text="Ctrl+F" Height="24" Padding="6,0" FontSize="11" BorderBrush="#CCC" BorderThickness="1"/>
          </Grid>
          <Separator Margin="0,0,0,12"/>
          <TextBlock Text="Features" FontSize="12" FontWeight="SemiBold" Foreground="#1E3A5F" Margin="0,0,0,8"/>
          <CheckBox x:Name="chkSettingsLiveFilter" Content="Enable live filter on DataGrids" IsChecked="True" FontSize="11" Margin="0,0,0,6"/>
          <CheckBox x:Name="chkSettingsConfirmDestructive" Content="Confirm before Enable/Disable/Reset" IsChecked="True" FontSize="11" Margin="0,0,0,6"/>
          <CheckBox x:Name="chkSettingsRowCount" Content="Show row count below grids" IsChecked="True" FontSize="11" Margin="0,0,0,6"/>
        </StackPanel>
      </TabItem>
      <TabItem Header="Audit Policies">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="4"/>
            <RowDefinition Height="160" MinHeight="80"/>
          </Grid.RowDefinitions>
          <!-- Info + buttons -->
          <StackPanel Grid.Row="0" Margin="8,8,8,4">
            <Border Background="#FFF8E1" BorderBrush="#F9A825" BorderThickness="1" CornerRadius="4" Padding="8,6" Margin="0,0,0,8">
              <TextBlock TextWrapping="Wrap" FontSize="11" Foreground="#5D4037"
                Text="GPO path: Computer Config - Windows Settings - Security Settings - Advanced Audit Policy Configuration. Check Current Status reads local auditpol. Apply sets policies directly on this DC."/>
            </Border>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
              <Button x:Name="btnCheckAudit"  Content="Check Current Status" Width="170" Height="26" Background="#1E6EB5" Foreground="White" BorderThickness="0" FontWeight="SemiBold" Cursor="Hand" Margin="0,0,8,0"/>
              <Button x:Name="btnApplyAudit"  Content="Apply via auditpol"   Width="150" Height="26" Background="#E74C3C" Foreground="White" BorderThickness="0" FontWeight="SemiBold" Cursor="Hand" Margin="0,0,8,0"/>
              <Button x:Name="btnSelectAllS"  Content="All Success"           Width="90"  Height="26" BorderBrush="#555" BorderThickness="1" Cursor="Hand" Margin="0,0,4,0" FontSize="11"/>
              <Button x:Name="btnSelectAllF"  Content="All Failure"           Width="90"  Height="26" BorderBrush="#555" BorderThickness="1" Cursor="Hand" Margin="0,0,4,0" FontSize="11"/>
              <Button x:Name="btnClearAll"    Content="Clear All"             Width="80"  Height="26" BorderBrush="#999" BorderThickness="1" Cursor="Hand" FontSize="11"/>
            </StackPanel>
          </StackPanel>
          <!-- Audit policy table -->
          <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
            <StackPanel Margin="8,0,8,8">
              <!-- Header row -->
              <Grid Margin="0,0,0,4">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="70"/>
                  <ColumnDefinition Width="70"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Subcategory" FontSize="11" FontWeight="Bold" Foreground="#1E3A5F"/>
                <TextBlock Grid.Column="1" Text="Success" FontSize="11" FontWeight="Bold" Foreground="#1E3A5F" HorizontalAlignment="Center"/>
                <TextBlock Grid.Column="2" Text="Failure" FontSize="11" FontWeight="Bold" Foreground="#1E3A5F" HorizontalAlignment="Center"/>
              </Grid>
              <Separator Margin="0,0,0,6"/>
              <!-- Account Logon -->
              <TextBlock Text="Account Logon" FontSize="11" FontWeight="SemiBold" Foreground="#1E3A5F" Background="#EEF2F7" Padding="4,2" Margin="0,4,0,2"/>
              <Grid x:Name="rowKerberos"  Margin="4,1,0,1"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="70"/><ColumnDefinition Width="70"/></Grid.ColumnDefinitions><TextBlock Grid.Column="0" Text="Kerberos Authentication Service (4768,4769,4771)" FontSize="11" VerticalAlignment="Center" ToolTip="Records all Kerberos ticket activity. Event 4768=TGT request (user logs on), 4769=Service ticket request (accessing a resource), 4771=Pre-authentication failed (wrong password via Kerberos). Essential for the Auth Audit feature in this tool. GPO path: Computer Configuration &gt; Policies &gt; Windows Settings &gt; Security Settings &gt; Advanced Audit Policy Configuration &gt; Account Logon &gt; Audit Kerberos Authentication Service"/><CheckBox x:Name="chkKerberosS" Grid.Column="1" HorizontalAlignment="Center" ToolTip="Audit Success"/><CheckBox x:Name="chkKerberosF" Grid.Column="2" HorizontalAlignment="Center" ToolTip="Audit Failure"/></Grid>
              <Grid x:Name="rowCredVal"   Margin="4,1,0,1"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="70"/><ColumnDefinition Width="70"/></Grid.ColumnDefinitions><TextBlock Grid.Column="0" Text="Credential Validation / NTLM (4776,4777)" FontSize="11" VerticalAlignment="Center" ToolTip="Records NTLM (legacy) authentication attempts. 4776=Successful NTLM validation, 4777=Failed NTLM validation. Important for machines/apps that still use NTLM instead of Kerberos (older servers, local accounts, some apps). GPO: Advanced Audit Policy &gt; Account Logon &gt; Audit Credential Validation"/><CheckBox x:Name="chkCredValS" Grid.Column="1" HorizontalAlignment="Center"/><CheckBox x:Name="chkCredValF" Grid.Column="2" HorizontalAlignment="Center"/></Grid>
              <!-- Logon/Logoff -->
              <TextBlock Text="Logon / Logoff" FontSize="11" FontWeight="SemiBold" Foreground="#1E3A5F" Background="#EEF2F7" Padding="4,2" Margin="0,4,0,2"/>
              <Grid Margin="4,1,0,1"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="70"/><ColumnDefinition Width="70"/></Grid.ColumnDefinitions><TextBlock Grid.Column="0" Text="Logon (4624, 4625)" FontSize="11" VerticalAlignment="Center" ToolTip="Records every logon event. 4624=Successful logon (includes logon type: 2=console, 3=network, 10=RDP, 7=unlock), 4625=Failed logon (includes failure reason). Most important events for security monitoring. GPO: Advanced Audit Policy &gt; Logon/Logoff &gt; Audit Logon"/><CheckBox x:Name="chkLogonS" Grid.Column="1" HorizontalAlignment="Center"/><CheckBox x:Name="chkLogonF" Grid.Column="2" HorizontalAlignment="Center"/></Grid>
              <Grid Margin="4,1,0,1"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="70"/><ColumnDefinition Width="70"/></Grid.ColumnDefinitions><TextBlock Grid.Column="0" Text="Logoff (4634)" FontSize="11" VerticalAlignment="Center" ToolTip="Records session termination. Useful for calculating session duration. Lower value audit - success only recommended. GPO: Advanced Audit Policy &gt; Logon/Logoff &gt; Audit Logoff"/><CheckBox x:Name="chkLogoffS" Grid.Column="1" HorizontalAlignment="Center"/><CheckBox x:Name="chkLogoffF" Grid.Column="2" HorizontalAlignment="Center"/></Grid>
              <Grid Margin="4,1,0,1"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="70"/><ColumnDefinition Width="70"/></Grid.ColumnDefinitions><TextBlock Grid.Column="0" Text="Account Lockout (4740)" FontSize="11" VerticalAlignment="Center" ToolTip="Records when a user account is locked out. Contains the computer name that caused the lockout (caller computer). Essential for diagnosing lockout storms. Enable Failure only. GPO: Advanced Audit Policy &gt; Logon/Logoff &gt; Audit Account Lockout"/><CheckBox x:Name="chkLockoutS" Grid.Column="1" HorizontalAlignment="Center"/><CheckBox x:Name="chkLockoutF" Grid.Column="2" HorizontalAlignment="Center"/></Grid>
              <Grid Margin="4,1,0,1"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="70"/><ColumnDefinition Width="70"/></Grid.ColumnDefinitions><TextBlock Grid.Column="0" Text="Special Logon (4672)" FontSize="11" VerticalAlignment="Center" ToolTip="4672=Logon with admin-equivalent privileges (SeDebugPrivilege, SeTcbPrivilege etc). Fires for every admin logon. Essential for tracking who used admin rights. GPO: Advanced Audit Policy &gt; Logon/Logoff &gt; Special Logon"/><CheckBox x:Name="chkSpecLogonS" Grid.Column="1" HorizontalAlignment="Center"/><CheckBox x:Name="chkSpecLogonF" Grid.Column="2" HorizontalAlignment="Center"/></Grid>
              <!-- Account Management -->
              <TextBlock Text="Account Management" FontSize="11" FontWeight="SemiBold" Foreground="#1E3A5F" Background="#EEF2F7" Padding="4,2" Margin="0,4,0,2"/>
              <Grid Margin="4,1,0,1"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="70"/><ColumnDefinition Width="70"/></Grid.ColumnDefinitions><TextBlock Grid.Column="0" Text="User Account Management (4720-4738)" FontSize="11" VerticalAlignment="Center" ToolTip="Records all changes to user accounts: 4720=Created, 4722=Enabled, 4723=Pwd change attempt, 4724=Pwd reset, 4725=Disabled, 4726=Deleted, 4738=Account changed. Compliance requirement for most security standards. GPO: Advanced Audit Policy &gt; Account Management &gt; Audit User Account Management"/><CheckBox x:Name="chkUserMgmtS" Grid.Column="1" HorizontalAlignment="Center"/><CheckBox x:Name="chkUserMgmtF" Grid.Column="2" HorizontalAlignment="Center"/></Grid>
              <Grid Margin="4,1,0,1"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="70"/><ColumnDefinition Width="70"/></Grid.ColumnDefinitions><TextBlock Grid.Column="0" Text="Security Group Management (4727-4756)" FontSize="11" VerticalAlignment="Center" ToolTip="Records changes to security groups: member added (4728 global/4732 local/4756 universal), member removed (4729/4733/4757), group created/deleted. Critical for detecting privilege escalation. GPO: Advanced Audit Policy &gt; Account Management &gt; Audit Security Group Management"/><CheckBox x:Name="chkGroupMgmtS" Grid.Column="1" HorizontalAlignment="Center"/><CheckBox x:Name="chkGroupMgmtF" Grid.Column="2" HorizontalAlignment="Center"/></Grid>
              <Grid Margin="4,1,0,1"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="70"/><ColumnDefinition Width="70"/></Grid.ColumnDefinitions><TextBlock Grid.Column="0" Text="Computer Account Management (4741-4743)" FontSize="11" VerticalAlignment="Center" ToolTip="Records computer account changes: 4741=Created, 4742=Changed, 4743=Deleted. Useful for detecting rogue computer accounts joining the domain. GPO: Advanced Audit Policy &gt; Account Management &gt; Audit Computer Account Management"/><CheckBox x:Name="chkCompMgmtS" Grid.Column="1" HorizontalAlignment="Center"/><CheckBox x:Name="chkCompMgmtF" Grid.Column="2" HorizontalAlignment="Center"/></Grid>
              <!-- Object Access -->
              <TextBlock Text="Object Access" FontSize="11" FontWeight="SemiBold" Foreground="#1E3A5F" Background="#EEF2F7" Padding="4,2" Margin="0,4,0,2"/>
              <Grid Margin="4,1,0,1"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="70"/><ColumnDefinition Width="70"/></Grid.ColumnDefinitions><TextBlock Grid.Column="0" Text="File System (requires SACL - high volume)" FontSize="11" VerticalAlignment="Center" ToolTip="WARNING: Very high event volume. Requires System ACL (SACL) configured on each file/folder separately. Events: 4663=Object access attempt, 4656=Handle requested. Enable SACL: right-click folder &gt; Properties &gt; Security &gt; Advanced &gt; Auditing tab. GPO: Advanced Audit Policy &gt; Object Access &gt; File System"/><CheckBox x:Name="chkFileFS" Grid.Column="1" HorizontalAlignment="Center"/><CheckBox x:Name="chkFileFail" Grid.Column="2" HorizontalAlignment="Center"/></Grid>
              <Grid Margin="4,1,0,1"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="70"/><ColumnDefinition Width="70"/></Grid.ColumnDefinitions><TextBlock Grid.Column="0" Text="File Share - Network share access (5140)" FontSize="11" VerticalAlignment="Center" ToolTip="Records access to network shares. 5140=A network share object was accessed, 5145=Share object access check (detailed). Useful for tracking who accesses shared folders. Less noisy than File System auditing. GPO: Advanced Audit Policy &gt; Object Access &gt; Audit File Share"/><CheckBox x:Name="chkShareS" Grid.Column="1" HorizontalAlignment="Center"/><CheckBox x:Name="chkShareF" Grid.Column="2" HorizontalAlignment="Center"/></Grid>
              <Grid Margin="4,1,0,1"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="70"/><ColumnDefinition Width="70"/></Grid.ColumnDefinitions><TextBlock Grid.Column="0" Text="Directory Service Access (4662)" FontSize="11" VerticalAlignment="Center" ToolTip="Records access to Active Directory objects when SACL is configured on the AD object. 4662=Operation performed on AD object. Requires additional SACL configuration in ADSI Edit. High volume. GPO: Advanced Audit Policy &gt; DS Access &gt; Audit Directory Service Access"/><CheckBox x:Name="chkDSS" Grid.Column="1" HorizontalAlignment="Center"/><CheckBox x:Name="chkDSF" Grid.Column="2" HorizontalAlignment="Center"/></Grid>
              <Grid Margin="4,1,0,1"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="70"/><ColumnDefinition Width="70"/></Grid.ColumnDefinitions><TextBlock Grid.Column="0" Text="Directory Service Changes (4720 in DS)" FontSize="11" VerticalAlignment="Center" ToolTip="Records attribute-level changes to AD objects (who changed what attribute, old value, new value). 4720/4738 in DS context. Essential for AD change auditing and compliance. GPO: Advanced Audit Policy &gt; DS Access &gt; Audit Directory Service Changes"/><CheckBox x:Name="chkDSChS" Grid.Column="1" HorizontalAlignment="Center"/><CheckBox x:Name="chkDSChF" Grid.Column="2" HorizontalAlignment="Center"/></Grid>
              <!-- Policy Change -->
              <TextBlock Text="Policy Change" FontSize="11" FontWeight="SemiBold" Foreground="#1E3A5F" Background="#EEF2F7" Padding="4,2" Margin="0,4,0,2"/>
              <Grid Margin="4,1,0,1"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="70"/><ColumnDefinition Width="70"/></Grid.ColumnDefinitions><TextBlock Grid.Column="0" Text="Audit Policy Change (4719)" FontSize="11" VerticalAlignment="Center" ToolTip="Records changes to audit policies themselves. 4719=System audit policy was changed. Always enable this - if someone disables auditing, you need to know. GPO: Advanced Audit Policy &gt; Policy Change &gt; Audit Audit Policy Change"/><CheckBox x:Name="chkPolChS" Grid.Column="1" HorizontalAlignment="Center"/><CheckBox x:Name="chkPolChF" Grid.Column="2" HorizontalAlignment="Center"/></Grid>
              <Grid Margin="4,1,0,1"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="70"/><ColumnDefinition Width="70"/></Grid.ColumnDefinitions><TextBlock Grid.Column="0" Text="Authentication Policy Change (4706,4707)" FontSize="11" VerticalAlignment="Center" ToolTip="Records changes to Kerberos policy, trust relationships, and authentication settings. 4706=New trust created, 4707=Trust removed. GPO: Advanced Audit Policy &gt; Policy Change &gt; Audit Authentication Policy Change"/><CheckBox x:Name="chkAuthPolS" Grid.Column="1" HorizontalAlignment="Center"/><CheckBox x:Name="chkAuthPolF" Grid.Column="2" HorizontalAlignment="Center"/></Grid>
              <!-- Privilege Use -->
              <TextBlock Text="Privilege Use" FontSize="11" FontWeight="SemiBold" Foreground="#1E3A5F" Background="#EEF2F7" Padding="4,2" Margin="0,4,0,2"/>
              <Grid Margin="4,1,0,1"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="70"/><ColumnDefinition Width="70"/></Grid.ColumnDefinitions><TextBlock Grid.Column="0" Text="Sensitive Privilege Use (4672, 4673)" FontSize="11" VerticalAlignment="Center" ToolTip="Records use of sensitive Windows privileges: SeDebugPrivilege (debug any process), SeTcbPrivilege (act as OS), SeBackupPrivilege, etc. 4672=Assigned on logon, 4673=Sensitive privilege used. Can be noisy but important for detecting privilege abuse. GPO: Advanced Audit Policy &gt; Privilege Use &gt; Audit Sensitive Privilege Use"/><CheckBox x:Name="chkPrivS" Grid.Column="1" HorizontalAlignment="Center"/><CheckBox x:Name="chkPrivF" Grid.Column="2" HorizontalAlignment="Center"/></Grid>
              <!-- System -->
              <TextBlock Text="System" FontSize="11" FontWeight="SemiBold" Foreground="#1E3A5F" Background="#EEF2F7" Padding="4,2" Margin="0,4,0,2"/>
              <Grid Margin="4,1,0,1"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="70"/><ColumnDefinition Width="70"/></Grid.ColumnDefinitions><TextBlock Grid.Column="0" Text="Security State Change (4608,4609)" FontSize="11" VerticalAlignment="Center" ToolTip="Records Windows security subsystem events: 4608=Windows starting up, 4609=Shutting down, 1102=Audit log cleared (critical - someone is covering tracks!). Enable Failure only for log cleared detection. GPO: Advanced Audit Policy &gt; System &gt; Audit Security State Change"/><CheckBox x:Name="chkSecStateS" Grid.Column="1" HorizontalAlignment="Center"/><CheckBox x:Name="chkSecStateF" Grid.Column="2" HorizontalAlignment="Center"/></Grid>
              <Grid Margin="4,1,0,1"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="70"/><ColumnDefinition Width="70"/></Grid.ColumnDefinitions><TextBlock Grid.Column="0" Text="System Integrity (4612)" FontSize="11" VerticalAlignment="Center" ToolTip="Records events that violate audit system integrity: 4612=Audit queues full (events being lost), 4615=Invalid use of LPC. Useful for detecting audit log saturation. GPO: Advanced Audit Policy &gt; System &gt; Audit System Integrity"/><CheckBox x:Name="chkSysIntS" Grid.Column="1" HorizontalAlignment="Center"/><CheckBox x:Name="chkSysIntF" Grid.Column="2" HorizontalAlignment="Center"/></Grid>
            </StackPanel>
          </ScrollViewer>
          <!-- GridSplitter -->
          <GridSplitter Grid.Row="2" Height="4" HorizontalAlignment="Stretch" VerticalAlignment="Center" Background="#CCD3DC" ShowsPreview="True" ResizeBehavior="PreviousAndNext"/>
          <!-- Output console -->
          <TextBox Grid.Row="3" x:Name="txtAuditStatus" IsReadOnly="True" TextWrapping="NoWrap"
                   FontSize="10" FontFamily="Consolas" Background="#1E1E1E" Foreground="#00FF00"
                   VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                   BorderThickness="0" Padding="8"/>
        </Grid>
      </TabItem>
    </TabControl>
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
      <Button x:Name="btnSettingsSave"   Content="Save"   Width="80" Height="28" Background="#1E6EB5" Foreground="White" BorderThickness="0" FontWeight="SemiBold" Cursor="Hand" Margin="0,0,8,0"/>
      <Button x:Name="btnSettingsCancel" Content="Cancel" Width="80" Height="28" BorderBrush="#CCC" BorderThickness="1" Cursor="Hand"/>
    </StackPanel>
  </Grid>
</Window>
'@)
    $setR = [System.Xml.XmlNodeReader]::new($setXml)
    $setW = [Windows.Markup.XamlReader]::Load($setR)
    $setW.Owner = $Window
    $setW.FindName("chkSettingsLiveFilter").IsChecked = $Script:LiveFilterEnabled

    # Store in Script scope for inner scriptblock access (PS5.1 closure workaround)
    $Script:AuditSetW = $setW
    $Script:AuditMap  = $auditMap
    function F { param($n) $Script:AuditSetW.FindName($n) }

    # Map: auditpol subcategory name -> {S=successCheckbox, F=failCheckbox}
    $auditMap = @{
        "Kerberos Authentication Service"  = @{S="chkKerberosS"; F="chkKerberosF"}
        "Kerberos Service Ticket Operations" = @{S="chkKerberosS"; F="chkKerberosF"}
        "Credential Validation"            = @{S="chkCredValS";  F="chkCredValF"}
        "Logon"                            = @{S="chkLogonS";    F="chkLogonF"}
        "Logoff"                           = @{S="chkLogoffS";   F="chkLogoffF"}
        "Account Lockout"                  = @{S="chkLockoutS";  F="chkLockoutF"}
        "Special Logon"                    = @{S="chkSpecLogonS";F="chkSpecLogonF"}
        "User Account Management"          = @{S="chkUserMgmtS"; F="chkUserMgmtF"}
        "Security Group Management"        = @{S="chkGroupMgmtS";F="chkGroupMgmtF"}
        "Computer Account Management"      = @{S="chkCompMgmtS"; F="chkCompMgmtF"}
        "File System"                      = @{S="chkFileFS";    F="chkFileFail"}
        "File Share"                       = @{S="chkShareS";    F="chkShareF"}
        "Directory Service Access"         = @{S="chkDSS";       F="chkDSF"}
        "Directory Service Changes"        = @{S="chkDSChS";     F="chkDSChF"}
        "Audit Policy Change"              = @{S="chkPolChS";    F="chkPolChF"}
        "Authentication Policy Change"     = @{S="chkAuthPolS";  F="chkAuthPolF"}
        "Sensitive Privilege Use"          = @{S="chkPrivS";     F="chkPrivF"}
        "Security State Change"            = @{S="chkSecStateS"; F="chkSecStateF"}
        "System Integrity"                 = @{S="chkSysIntS";   F="chkSysIntF"}
    }

    # Check Current Status - reads auditpol and ticks checkboxes
    $Script:AuditSetW.FindName("btnCheckAudit").Add_Click({
        $txtS = $Script:AuditSetW.FindName("txtAuditStatus")
        $txtS.Text = "Reading auditpol..."
        try {
            $out = auditpol /get /category:* 2>&1
            $rawText = $out -join "`n"
            $txtS.Text = $rawText
            # Parse and tick checkboxes
            foreach ($line in $out) {
                if ($line -match '^\s{2}(.+?)\s{2,}(Success and Failure|Success|Failure|No Auditing)\s*$') {
                    $sub = $Matches[1].Trim(); $setting = $Matches[2].Trim()
                    if ($auditMap.ContainsKey($sub)) {
                        $m = $auditMap[$sub]
                        $Script:AuditSetW.FindName($m.S).IsChecked = ($setting -match "Success")
                        $Script:AuditSetW.FindName($m.F).IsChecked = ($setting -match "Failure")
                    }
                }
            }
        } catch { $Script:AuditSetW.FindName("txtAuditStatus").Text = "Error: $($_.Exception.Message)" }
    })

    # Select All Success / All Failure / Clear All
    $Script:AuditSetW.FindName("btnSelectAllS").Add_Click({ foreach($n in $Script:AuditMap.Values){ $Script:AuditSetW.FindName($n.S).IsChecked=$true } })
    $Script:AuditSetW.FindName("btnSelectAllF").Add_Click({ foreach($n in $Script:AuditMap.Values){ $Script:AuditSetW.FindName($n.F).IsChecked=$true } })
    $Script:AuditSetW.FindName("btnClearAll").Add_Click({ foreach($n in $Script:AuditMap.Values){ $Script:AuditSetW.FindName($n.S).IsChecked=$false; $Script:AuditSetW.FindName($n.F).IsChecked=$false } })

    # Apply via auditpol
    $Script:AuditSetW.FindName("btnApplyAudit").Add_Click({
        $txtS = $Script:AuditSetW.FindName("txtAuditStatus")
        $log = [System.Text.StringBuilder]::new()
        function AuditSet { param($sub,$suc,$fail)
            $s=if($suc){"enable"}else{"disable"}; $f=if($fail){"enable"}else{"disable"}
            try { auditpol /set /subcategory:"$sub" /success:$s /failure:$f 2>&1|Out-Null; [void]$log.AppendLine("OK: $sub (S=$s F=$f)") }
            catch { [void]$log.AppendLine("ERR: $sub") }
        }
        foreach ($sub in $Script:AuditMap.Keys) {
            $m = $Script:AuditMap[$sub]
            AuditSet $sub ($Script:AuditSetW.FindName($m.S).IsChecked -eq $true) ($Script:AuditSetW.FindName($m.F).IsChecked -eq $true)
        }
        $txtS.Text = $log.ToString() + "`nDone. Run: gpupdate /force on all DCs."
    })

    $Script:AuditSetW.FindName("btnSettingsCancel").Add_Click({ $Script:AuditSetW.Close() })
    $Script:AuditSetW.FindName("btnSettingsSave").Add_Click({
        $Script:LiveFilterEnabled = (F("chkSettingsLiveFilter").IsChecked -eq $true)
        $setW.Close(); Show-Info "Settings saved."
    })
    $setW.ShowDialog() | Out-Null
})




# ── LIVE FILTER (Users) ───────────────────────────────────────────────────────
$txtUserLiveFilter.Add_TextChanged({
    if (-not $Script:LiveFilterEnabled) { return }
    $filterText = $txtUserLiveFilter.Text.Trim()
    if ($null -eq $Script:UserCV) { return }
    if ([string]::IsNullOrEmpty($filterText)) {
        $Script:UserCV.Filter = $null
    } else {
        $ft = $filterText
        $Script:UserCV.Filter = [Predicate[object]]{
            param($item)
            $item.Username    -like "*$ft*" -or
            $item.DisplayName -like "*$ft*" -or
            $item.Email       -like "*$ft*" -or
            $item.Department  -like "*$ft*" -or
            $item.Title       -like "*$ft*"
        }
    }
    $cnt = ($Script:UserCV | Measure-Object).Count
    $lblUsersRowCount.Text = "Found $cnt users$(if($filterText){' (filtered)'})"
})

# ── CONTEXT MENU - Copy cell / Copy row ────────────────────────────────────
function Get-GridCellValue {
    param($grid)
    $sel = $grid.SelectedItem; $col = $grid.CurrentColumn
    if (-not $sel -or -not $col) { return $null }
    $prop = $col.SortMemberPath
    if ([string]::IsNullOrEmpty($prop)) { $prop = $col.Header }
    try { return ($sel | Select-Object -ExpandProperty $prop -ErrorAction Stop) } catch { return $null }
}
function Get-GridRowValue {
    param($grid)
    $sel = $grid.SelectedItems
    if (-not $sel) { return $null }
    $rows = foreach ($item in $sel) {
        ($item.PSObject.Properties | ForEach-Object { $_.Value }) -join "`t"
    }
    return $rows -join "`n"
}
$ctxCopyCell.Add_Click({
    $v = Get-GridCellValue -grid $gridUsers
    if ($v) { [System.Windows.Clipboard]::SetText("$v") }
})
$ctxCopyRow.Add_Click({
    $v = Get-GridRowValue -grid $gridUsers
    if ($v) { [System.Windows.Clipboard]::SetText($v) }
})
$ctxCopyCellG.Add_Click({
    $v = Get-GridCellValue -grid $gridGroups
    if ($v) { [System.Windows.Clipboard]::SetText("$v") }
})
$ctxCopyRowG.Add_Click({
    $v = Get-GridRowValue -grid $gridGroups
    if ($v) { [System.Windows.Clipboard]::SetText($v) }
})
$ctxCompPing = B "ctxCompPing"; $ctxCompRDP = B "ctxCompRDP"
$ctxCopyCellC.Add_Click({
    $v = Get-GridCellValue -grid $gridComputers
    if ($v) { [System.Windows.Clipboard]::SetText("$v") }
})
$ctxCopyRowC.Add_Click({
    $v = Get-GridRowValue -grid $gridComputers
    if ($v) { [System.Windows.Clipboard]::SetText($v) }
})
$ctxCompPing.Add_Click({
    $sel = $gridComputers.SelectedItem
    if (-not $sel) { return }
    $t = if ($sel.DNSHostName) { $sel.DNSHostName } else { $sel.Name }
    Start-Process "cmd" -ArgumentList "/k ping -t $t" -ErrorAction SilentlyContinue
})
$ctxCompRDP.Add_Click({
    $sel = $gridComputers.SelectedItem
    if (-not $sel) { return }
    $t = if ($sel.DNSHostName) { $sel.DNSHostName } else { $sel.Name }
    Start-Process "mstsc" -ArgumentList "/v:$t" -ErrorAction SilentlyContinue
})

# ── USER DETAIL PANEL ─────────────────────────────────────────────────────────
$ctxUserDetail.Add_Click({ Show-UserDetails })
$gridUsers.Add_MouseDoubleClick({
    param($sender, $e)
    if ($gridUsers.SelectedItem) { Show-UserDetails }
})

function Show-UserDetails {
    $sel = $gridUsers.SelectedItem
    if (-not $sel) { Show-Err "Select a user first."; return }
    if (-not (Ensure-ADModule)) { return }
    try {
        $u = Get-ADUser -Identity $sel.Username -Properties * -ErrorAction Stop
        $uGroups = @(Get-ADPrincipalGroupMembership -Identity $u.SamAccountName -ErrorAction Stop | Sort-Object Name)
        $Script:UserDetailUser   = $u
        $Script:UserDetailGroups = $uGroups

        [xml]$detXml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="User Details" Width="860" Height="620" MinWidth="700" MinHeight="500"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize" Background="#F8F9FA">
  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <!-- Header -->
    <TextBlock Grid.Row="0" x:Name="lblDetTitle" FontSize="15" FontWeight="Bold" Foreground="#1E3A5F" Margin="0,0,0,10"/>
    <!-- Main content: Info + Groups -->
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="4"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <!-- Left: User Info -->
      <Border Grid.Column="0" BorderBrush="#DDE1E7" BorderThickness="1" CornerRadius="4">
        <TextBox x:Name="txtDetail" IsReadOnly="True" FontFamily="Consolas" FontSize="11"
                 TextWrapping="Wrap" AcceptsReturn="True" VerticalScrollBarVisibility="Auto"
                 Background="#1a1a2e" Foreground="#00e676" Padding="10" BorderThickness="0"/>
      </Border>
      <GridSplitter Grid.Column="1" Width="4" HorizontalAlignment="Center" VerticalAlignment="Stretch" Background="#CCD3DC" ShowsPreview="True"/>
      <!-- Right: Group Membership -->
      <Grid Grid.Column="2">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Group Membership" FontSize="12" FontWeight="SemiBold" Foreground="#1E3A5F" Margin="4,0,0,6"/>
        <Border Grid.Row="1" BorderBrush="#DDE1E7" BorderThickness="1" CornerRadius="4">
          <ListBox x:Name="lstGroups" FontSize="12" BorderThickness="0"
                   SelectionMode="Extended" ToolTip="Select one or more groups. Use Ctrl+Click for multiple."/>
        </Border>
        <!-- Add Group -->
        <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,8,0,4">
          <TextBox x:Name="txtAddGroup" Width="160" Height="26" FontSize="11"
                   VerticalContentAlignment="Center" Padding="6,0" BorderBrush="#CCC" BorderThickness="1"
                   ToolTip="Type group name (partial OK) then click Add, or use Browse to search"/>
          <Button x:Name="btnBrowseGroup" Content="Browse..." Width="70" Height="26"
                  BorderBrush="#555" BorderThickness="1"
                  FontSize="11" Cursor="Hand" Margin="4,0,0,0" ToolTip="Search and select a group from AD"/>
          <Button x:Name="btnAddGroup" Content="Add" Width="60" Height="26"
                  Background="#27AE60" Foreground="White" BorderThickness="0"
                  FontWeight="SemiBold" Cursor="Hand" Margin="4,0,0,0" ToolTip="Add user to the group in the text box"/>
        </StackPanel>
        <Button Grid.Row="3" x:Name="btnRemoveGroup" Content="Remove from Selected Groups"
                Height="28" Background="#E74C3C" Foreground="White" BorderThickness="0"
                FontWeight="SemiBold" Cursor="Hand" ToolTip="Remove user from all selected groups in the list above"/>
      </Grid>
    </Grid>
    <!-- Footer -->
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
      <Button x:Name="btnDetCopy"  Content="Copy Info" Width="90" Height="28" Background="#1E6EB5" Foreground="White" BorderThickness="0" FontWeight="SemiBold" Cursor="Hand" Margin="0,0,8,0"/>
      <Button x:Name="btnDetClose" Content="Close" Width="80" Height="28" BorderBrush="#CCC" BorderThickness="1" Cursor="Hand"/>
    </StackPanel>
  </Grid>
</Window>
'@
        $detR = [System.Xml.XmlNodeReader]::new($detXml)
        $detW = [Windows.Markup.XamlReader]::Load($detR)
        $detW.Owner = $Window

        $lblTitle  = $detW.FindName("lblDetTitle")
        $txtDet    = $detW.FindName("txtDetail")
        $Script:UserDetailLstGrps = $detW.FindName("lstGroups")
        $lstGrps = $Script:UserDetailLstGrps
        $txtAddGrp = $detW.FindName("txtAddGroup")
        $btnAdd      = $detW.FindName("btnAddGroup")
        $btnBrowseGrp = $detW.FindName("btnBrowseGroup")
        $btnRemove = $detW.FindName("btnRemoveGroup")

        $lblTitle.Text = "User Details: $($u.SamAccountName)  ($($u.DisplayName))"

        # Build info text
        $uDN = $u.DistinguishedName
        $dr = try { (Get-ADUser -Filter "Manager -eq '$uDN'" -EA Stop | Measure-Object).Count } catch { 0 }
        $info  = "Username    : $($u.SamAccountName)`n"
        $info += "Display     : $($u.DisplayName)`n"
        $info += "Email       : $($u.mail)`n"
        $info += "Title       : $($u.Title)`n"
        $info += "Department  : $($u.Department)`n"
        $info += "Office      : $($u.Office)`n"
        $info += "Phone       : $($u.telephoneNumber)`n"
        $info += "Mobile      : $($u.mobile)`n"
        $mgr2 = if($u.Manager){($u.Manager -split ',')[0] -replace '^CN=',''}else{''}
        $info += "Manager     : $mgr2`n"
        $info += "Direct Rep. : $dr`n"
        $info += "Description : $($u.Description)`n"
        $info += "OU          : $($u.DistinguishedName -replace '^CN=[^,]+,','')`n"
        $info += "Enabled     : $($u.Enabled)`n"
        $info += "Locked Out  : $($u.LockedOut)`n"
        $info += "Created     : $($u.WhenCreated)`n"
        $info += "Last Logon  : $($u.LastLogonDate)`n"
        $info += "Pwd LastSet : $($u.PasswordLastSet)`n"
        $info += "Pwd Never   : $($u.PasswordNeverExpires)`n"
        $info += "Pwd Expires : $($u.AccountExpirationDate)`n"
        $info += "SID         : $($u.SID)`n"
        $info += "DN          : $($u.DistinguishedName)"
        $txtDet.Text = $info

        # Populate groups
        $lstGrps.Items.Clear()
        foreach ($g in $uGroups) { [void]$lstGrps.Items.Add($g.Name) }

        # Add to group
        $btnAdd.Add_Click({
            $gname = $txtAddGrp.Text.Trim()
            if (-not $gname) { return }
            try {
                $grp = Get-ADGroup -Filter "Name -like '$gname'" -ErrorAction Stop | Select-Object -First 1
                if (-not $grp) { [System.Windows.MessageBox]::Show("Group '$gname' not found.","AD Manager","OK","Warning")|Out-Null; return }
                Add-ADGroupMember -Identity $grp -Members $Script:UserDetailUser.SamAccountName -ErrorAction Stop
                if (-not ($lstGrps.Items -contains $grp.Name)) { [void]$lstGrps.Items.Add($grp.Name) }
                $txtAddGrp.Text = ""
                [System.Windows.MessageBox]::Show("Added to $($grp.Name).","AD Manager","OK","Information")|Out-Null
            } catch { [System.Windows.MessageBox]::Show("Error: $($_.Exception.Message)","Error","OK","Error")|Out-Null }
        })

        # Browse groups dialog
        $btnBrowseGrp.Add_Click({
            # Search dialog
            [xml]$browseXml = [xml]([string]@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Browse Groups" Width="480" Height="400" MinWidth="350" MinHeight="300"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize" Background="#F8F9FA">
  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,8">
      <TextBox x:Name="txtGrpSearch" Width="280" Height="28" FontSize="12"
               VerticalContentAlignment="Center" Padding="6,0" BorderBrush="#CCC" BorderThickness="1"
               ToolTip="Type group name (partial) and press Enter or click Search"/>
      <Button x:Name="btnGrpSearch" Content="Search" Width="80" Height="28"
              Background="#1E6EB5" Foreground="White" BorderThickness="0"
              FontWeight="SemiBold" Cursor="Hand" Margin="6,0,0,0"/>
    </StackPanel>
    <ListBox x:Name="lstGrpResults" Grid.Row="1" FontSize="12"
             BorderBrush="#DDE1E7" BorderThickness="1" SelectionMode="Extended"
             ToolTip="Use Ctrl+Click or Shift+Click to select multiple groups"/>
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
      <Button x:Name="btnGrpSelect" Content="Select" Width="80" Height="28"
              Background="#27AE60" Foreground="White" BorderThickness="0"
              FontWeight="SemiBold" Cursor="Hand" Margin="0,0,8,0"/>
      <Button x:Name="btnGrpCancel" Content="Cancel" Width="80" Height="28"
              BorderBrush="#CCC" BorderThickness="1" Cursor="Hand"/>
    </StackPanel>
  </Grid>
</Window>
'@)
            $bR = [System.Xml.XmlNodeReader]::new($browseXml)
            $bW = [Windows.Markup.XamlReader]::Load($bR)
            $bW.Owner = $detW
            $bSearch = $bW.FindName("txtGrpSearch")
            $bList   = $bW.FindName("lstGrpResults")
            $Script:BrowseSelectedGroups = @()

            $Script:BrowseSearchCtrl = $bSearch
            $Script:BrowseListCtrl   = $bList
            $Script:BrowseDoSearch = {
                $q = $Script:BrowseSearchCtrl.Text.Trim()
                $Script:BrowseListCtrl.Items.Clear()
                try {
                    $filter = if ($q) { "Name -like '*$q*'" } else { "Name -like '*'" }
                    $groups = Get-ADGroup -Filter $filter -ResultSetSize 500 -EA Stop | Sort-Object Name
                    foreach ($g in $groups) { [void]$Script:BrowseListCtrl.Items.Add($g.Name) }
                    if ($Script:BrowseListCtrl.Items.Count -eq 0) { [void]$Script:BrowseListCtrl.Items.Add("(no results)") }
                } catch { [void]$Script:BrowseListCtrl.Items.Add("Error: $($_.Exception.Message)") }
            }
            # Load all groups immediately on open
            & $Script:BrowseDoSearch
            $bSearch.Add_KeyDown({ param($s2,$e2) if($e2.Key -eq "Return"){ & $Script:BrowseDoSearch } })
            $bW.FindName("btnGrpSearch").Add_Click({ & $Script:BrowseDoSearch })
            $bList.Add_MouseDoubleClick({
                $sel = @($bList.SelectedItems | Where-Object { $_ -notlike '(*' })
                if ($sel.Count -gt 0) { $Script:BrowseSelectedGroups = $sel; $bW.Close() }
            })
            $bW.FindName("btnGrpSelect").Add_Click({
                $sel = @($bList.SelectedItems | Where-Object { $_ -notlike '(*' })
                if ($sel.Count -gt 0) { $Script:BrowseSelectedGroups = $sel; $bW.Close() }
            })
            $bW.FindName("btnGrpCancel").Add_Click({ $bW.Close() })
            $bW.ShowDialog() | Out-Null
            if ($Script:BrowseSelectedGroups -and $Script:BrowseSelectedGroups.Count -gt 0) {
                # Add each selected group
                foreach ($gname in $Script:BrowseSelectedGroups) {
                    try {
                        $grp = Get-ADGroup -Identity $gname -ErrorAction Stop
                        Add-ADGroupMember -Identity $grp -Members $Script:UserDetailUser.SamAccountName -ErrorAction Stop
                        if (-not ($Script:UserDetailLstGrps.Items -contains $grp.Name)) { [void]$Script:UserDetailLstGrps.Items.Add($grp.Name) }
                    } catch { [System.Windows.MessageBox]::Show("Error adding to $gname`: $($_.Exception.Message)","Error","OK","Error")|Out-Null }
                }
                [System.Windows.MessageBox]::Show("Added to $($Script:BrowseSelectedGroups.Count) group(s).","Done","OK","Information")|Out-Null
            }
        })

        # Remove from groups
        $btnRemove.Add_Click({
            $selected = @($Script:UserDetailLstGrps.SelectedItems)
            if ($selected.Count -eq 0) { [System.Windows.MessageBox]::Show("Select one or more groups first.","AD Manager","OK","Warning")|Out-Null; return }
            $confirm = [System.Windows.MessageBox]::Show("Remove $($Script:UserDetailUser.SamAccountName) from $($selected.Count) group(s)?`n`n$($selected -join ', ')","Confirm","YesNo","Warning")
            if ($confirm -ne "Yes") { return }
            $errors = @()
            foreach ($gname in $selected) {
                try {
                    Remove-ADGroupMember -Identity $gname -Members $Script:UserDetailUser.SamAccountName -Confirm:$false -ErrorAction Stop
                    [void]$Script:UserDetailLstGrps.Items.Remove($gname)
                } catch { $errors += "$gname`: $($_.Exception.Message)" }
            }
            if ($errors) { [System.Windows.MessageBox]::Show("Errors:`n$($errors -join "`n")","Errors","OK","Warning")|Out-Null }
            else { [System.Windows.MessageBox]::Show("Removed from $($selected.Count) group(s).","Done","OK","Information")|Out-Null }
        })

        $detW.FindName("btnDetCopy").Add_Click({ [System.Windows.Clipboard]::SetText($info) })
        $detW.FindName("btnDetClose").Add_Click({ $detW.Close() })
        $detW.ShowDialog() | Out-Null
    } catch { Show-Err "Error loading user details: $($_.Exception.Message)" }
}


# ── HEATMAP IN USERS TAB ──────────────────────────────────────────────────────
function Load-UsersHeatmap {
    if (-not (Ensure-ADModule)) { return }
    # Reuse the same logic as Domain heatmap but populate icUsersHeatmap
    try {
        Set-Status "Loading logon heatmap..." 10
        $now    = Get-Date
        $users2 = Get-ADUser -Filter { Enabled -eq $true } -Properties LastLogonDate
        $buckets2 = [ordered]@{
            "Today / Yesterday" = 0; "2 - 7 days" = 0; "8 - 30 days" = 0
            "31 - 90 days" = 0; "91 - 180 days" = 0; "Over 180 days" = 0; "Never logged on" = 0
        }
        $Script:HeatmapBucketUsers2 = @{}
        foreach ($u in $users2) {
            $ll = $u.LastLogonDate
            $days = if ($ll) { ($now - $ll).TotalDays } else { 99999 }
            $bk = if ($days -le 2) {"Today / Yesterday"} elseif ($days -le 7) {"2 - 7 days"} elseif ($days -le 30) {"8 - 30 days"} elseif ($days -le 90) {"31 - 90 days"} elseif ($days -le 180) {"91 - 180 days"} elseif ($days -lt 9999) {"Over 180 days"} else {"Never logged on"}
            $buckets2[$bk]++
            if (-not $Script:HeatmapBucketUsers2.ContainsKey($bk)) { $Script:HeatmapBucketUsers2[$bk] = [System.Collections.Generic.List[object]]::new() }
            [void]$Script:HeatmapBucketUsers2[$bk].Add([PSCustomObject]@{Username=$u.SamAccountName;DisplayName=$u.DisplayName;LastLogon=$ll;DaysAgo=if($ll){[math]::Round($days,0)}else{"Never"}})
        }
        $total2 = ($users2 | Measure-Object).Count
        $colorMap2 = @{"Today / Yesterday"="#27AE60";"2 - 7 days"="#52BE80";"8 - 30 days"="#F39C12";"31 - 90 days"="#E67E22";"91 - 180 days"="#E74C3C";"Over 180 days"="#922B21";"Never logged on"="#7F8C8D"}
        $icUsersHeatmap.Dispatcher.Invoke([action]{
            $icUsersHeatmap.Items.Clear()
            foreach ($kv in $buckets2.GetEnumerator()) {
                $lbl2 = $kv.Key; $cnt2 = $kv.Value
                $pct2 = if ($total2 -gt 0) { [math]::Round($cnt2/$total2*100,1) } else { 0 }
                $hex2 = if ($colorMap2.ContainsKey($lbl2)) { $colorMap2[$lbl2] } else { "#888" }
                $brush2 = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString($hex2))
                $tile2 = New-Object System.Windows.Controls.Border
                $tile2.Background = $brush2; $tile2.CornerRadius = [System.Windows.CornerRadius]8
                $tile2.Margin = [System.Windows.Thickness]4; $tile2.Padding = [System.Windows.Thickness]"12,8,12,8"
                $tile2.MinWidth = 120; $tile2.Cursor = [System.Windows.Input.Cursors]::Hand; $tile2.Tag = $lbl2
                $sp2 = New-Object System.Windows.Controls.StackPanel
                $t1b = New-Object System.Windows.Controls.TextBlock; $t1b.Text = $lbl2; $t1b.Foreground = [System.Windows.Media.Brushes]::White; $t1b.FontSize = 11
                $t2b = New-Object System.Windows.Controls.TextBlock; $t2b.Text = "$cnt2 ($pct2%)"; $t2b.Foreground = [System.Windows.Media.Brushes]::White; $t2b.FontSize = 16; $t2b.FontWeight = [System.Windows.FontWeights]::Bold
                [void]$sp2.Children.Add($t1b); [void]$sp2.Children.Add($t2b); $tile2.Child = $sp2
                $tile2.Add_MouseLeftButtonUp({
                    param($src,$e2)
                    $bLabel = $src.Tag
                    if ($Script:HeatmapBucketUsers2 -and $Script:HeatmapBucketUsers2.ContainsKey($bLabel)) {
                        $gridUsersHeatmapDetail.ItemsSource = [object[]]@($Script:HeatmapBucketUsers2[$bLabel])
                        $lblUsersHeatmapDetailTitle.Text = "$bLabel  ($($Script:HeatmapBucketUsers2[$bLabel].Count) users)"
                        $borderUsersHeatmapDetail.Visibility = [System.Windows.Visibility]::Visible
                    }
                })
                [void]$icUsersHeatmap.Items.Add($tile2)
            }
        })
        $lblUsersHeatmapInfo.Text = "Total enabled: $total2 | $(Get-Date -Format 'HH:mm:ss')"
        Set-Status "Heatmap loaded." 100
    } catch { Set-Status "Error loading heatmap." 0 }
}
$btnShowHeatmap.Add_Click({
    if ($panelUsersHeatmap.Visibility -eq [System.Windows.Visibility]::Collapsed) {
        $panelUsersHeatmap.Visibility = [System.Windows.Visibility]::Visible
        Load-UsersHeatmap
    } else {
        $panelUsersHeatmap.Visibility = [System.Windows.Visibility]::Collapsed
    }
})

# ── EXCEL EXPORT ───────────────────────────────────────────────────────────────
function Export-ToExcel {
    param([object[]]$Data, [string]$DefaultName = "AD_Export.xlsx", [string]$SheetName = "Data")
    if (-not $Data -or $Data.Count -eq 0) { Show-Err "No data to export."; return }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter   = "CSV UTF-8 for Excel (*.csv)|*.csv|All files (*.*)|*.*"
    $dlg.FileName = $DefaultName -replace '\.xlsx$','.csv'
    if ($dlg.ShowDialog() -ne "OK") { return }
    $path = $dlg.FileName
    try {
        if (Get-Module -ListAvailable -Name ImportExcel -ErrorAction SilentlyContinue) {
            Import-Module ImportExcel -ErrorAction Stop
            $xlPath = $path -replace '\.csv$','.xlsx'
            $Data | Export-Excel -Path $xlPath -WorksheetName $SheetName -AutoSize -FreezeTopRow -TableName "ADData" -TableStyle Medium2
            Show-Info "Exported to Excel:`n$xlPath"
            return
        }
        # Fallback: CSV with UTF-8 BOM - opens correctly in Excel without garbled Greek
        $utf8bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllLines($path, ($Data | ConvertTo-Csv -NoTypeInformation), $utf8bom)
        Show-Info "Exported (CSV with UTF-8 BOM - opens correctly in Excel):`n$path`n`nFor true .xlsx: Install-Module ImportExcel -Scope CurrentUser"
    } catch { Show-Err "Export error: $($_.Exception.Message)" }
}
$btnExportUsersXlsx.Add_Click({ Export-ToExcel -Data $Script:CachedUsers -DefaultName "AD_Users.xlsx" -SheetName "Users" })
$menuExportExcel.Add_Click({
    # Export whatever is currently visible
    $ti = $tabMain.SelectedIndex
    $data = switch ($ti) {
        0  { $gridSystem.ItemsSource }
        3  { $Script:CachedShares }
        4  { $Script:CachedUsers }
        5  { $Script:CachedGroups }
        6  { $Script:CachedComputers }
        default { $null }
    }
    if ($data) { Export-ToExcel -Data $data -DefaultName "AD_Export.xlsx" }
    else { Show-Err "No exportable data on current tab." }
})

# ── CONFIRM DESTRUCTIVE ACTIONS ────────────────────────────────────────────────
# Wrap Enable/Disable with confirmation
$btnDisableSelected.Add_Click({
    $sel = $gridUsers.SelectedItems
    if (-not $sel -or $sel.Count -eq 0) { Show-Err "Select at least one user."; return }
    $cnt = $sel.Count
    $plural = if($cnt -gt 1){'s'}else{''}
    $names = ($sel | Select-Object -First 5 | ForEach-Object {$_.Username}) -join ', '
    $more  = if($cnt -gt 5){"`n...and $($cnt-5) more"}else{''}
    $r = [System.Windows.MessageBox]::Show("Disable $cnt account${plural}?`n`n${names}${more}", "Confirm Disable", "YesNo", "Warning")
    if ($r -eq "Yes") { Set-SelectedAccountState -Enable $false }
})

# ── KEYBOARD SHORTCUTS ────────────────────────────────────────────────────────
$Window.Add_KeyDown({
    param($s, $e)
    $ctrl = [System.Windows.Input.Keyboard]::IsKeyDown([System.Windows.Input.Key]::LeftCtrl) -or
            [System.Windows.Input.Keyboard]::IsKeyDown([System.Windows.Input.Key]::RightCtrl)
    # F5 = Refresh current tab
    if ($e.Key -eq [System.Windows.Input.Key]::F5) {
        $e.Handled = $true
        $ti = $tabMain.SelectedIndex
        switch ($ti) {
            0 { Load-SystemInfo }
            1 { Load-DomainInfo }
            2 { Load-OUTree }
            3 { Load-Shares }
            4 { Load-ADUsers -DisabledOnly ($chkDisabledUsers.IsChecked -eq $true) }
            5 { Load-ADGroups }
            6 { Load-ADComputers }
        }
    }
    # Ctrl+E = Export CSV current tab
    if ($ctrl -and $e.Key -eq [System.Windows.Input.Key]::E) {
        $e.Handled = $true
        $ti = $tabMain.SelectedIndex
        switch ($ti) {
            4 { Export-ToCSV -Data $Script:CachedUsers    -DefaultName "AD_Users.csv" }
            5 { Export-ToCSV -Data $Script:CachedGroups   -DefaultName "AD_Groups.csv" }
            6 { Export-ToCSV -Data $Script:CachedComputers -DefaultName "AD_Computers.csv" }
            3 { Export-ToCSV -Data $Script:CachedShares   -DefaultName "AD_Shares.csv" }
        }
    }
    # Ctrl+F = Focus live filter (Users tab)
    if ($ctrl -and $e.Key -eq [System.Windows.Input.Key]::F) {
        $e.Handled = $true
        if ($tabMain.SelectedIndex -eq 4) { $txtUserLiveFilter.Focus() }
    }
})

# ── OU TREE CONTEXT MENU ──────────────────────────────────────────────────────
$ctxOUCopy.Add_Click({
    $sel = $treeOU.SelectedItem
    if ($sel -and $sel.ToolTip) { [System.Windows.Clipboard]::SetText($sel.ToolTip) }
})
$ctxOULoadUsers.Add_Click({
    $sel = $treeOU.SelectedItem
    if (-not $sel) { return }
    $ouPath = $sel.ToolTip
    if ([string]::IsNullOrEmpty($ouPath)) { return }
    if (-not (Ensure-ADModule)) { return }
    try {
        $ouUsers = Get-ADUser -Filter * -SearchBase $ouPath -Properties DisplayName,mail,Enabled,LastLogonDate | ForEach-Object {
            [PSCustomObject]@{Username=$_.SamAccountName;DisplayName=$_.DisplayName;Email=$_.mail;Enabled=$_.Enabled;LastLogon=$_.LastLogonDate}
        }
        $cnt = ($ouUsers | Measure-Object).Count
        $ouNames = ($ouUsers | Select-Object -First 10 | ForEach-Object {$_.Username}) -join ', '
        $ouMore  = if($cnt -gt 10){"`n...and $($cnt-10) more"}else{''}
        Show-Info "Found $cnt users in OU:`n$ouPath`n`n${ouNames}${ouMore}"
    } catch { Show-Err "Error: $($_.Exception.Message)" }
})

# ── menuAbout version label fix (already updated above) ────────────────────

#endregion

# ── COMPUTER HEATMAP ──────────────────────────────────────────────────────────
function Load-ComputerHeatmap {
    if (-not (Ensure-ADModule)) { return }
    try {
        Set-Status "Loading computer heatmap..." 10
        $now   = Get-Date
        $comps = Get-ADComputer -Filter { Enabled -eq $true } -Properties LastLogonDate
        $buckets = [ordered]@{
            "Today / Yesterday" = 0; "2 - 7 days" = 0; "8 - 30 days" = 0
            "31 - 90 days" = 0; "91 - 180 days" = 0; "Over 180 days" = 0; "Never logged on" = 0
        }
        $Script:HeatmapBucketComps = @{}
        foreach ($c in $comps) {
            $ll = $c.LastLogonDate
            $days = if ($ll) { ($now - $ll).TotalDays } else { 99999 }
            $bk = if ($days -le 2) {"Today / Yesterday"} elseif ($days -le 7) {"2 - 7 days"} elseif ($days -le 30) {"8 - 30 days"} elseif ($days -le 90) {"31 - 90 days"} elseif ($days -le 180) {"91 - 180 days"} elseif ($days -lt 9999) {"Over 180 days"} else {"Never logged on"}
            $buckets[$bk]++
            if (-not $Script:HeatmapBucketComps.ContainsKey($bk)) { $Script:HeatmapBucketComps[$bk] = [System.Collections.Generic.List[object]]::new() }
            [void]$Script:HeatmapBucketComps[$bk].Add([PSCustomObject]@{Name=$c.Name;OS=$c.OperatingSystem;LastLogon=$ll;DaysAgo=if($ll){[math]::Round($days,0)}else{"Never"}})
        }
        $total = ($comps | Measure-Object).Count
        $colorMap = @{"Today / Yesterday"="#27AE60";"2 - 7 days"="#52BE80";"8 - 30 days"="#F39C12";"31 - 90 days"="#E67E22";"91 - 180 days"="#E74C3C";"Over 180 days"="#922B21";"Never logged on"="#7F8C8D"}
        $icComputerHeatmap.Dispatcher.Invoke([action]{
            $icComputerHeatmap.Items.Clear()
            foreach ($kv in $buckets.GetEnumerator()) {
                $lbl3 = $kv.Key; $cnt3 = $kv.Value
                $pct3 = if ($total -gt 0) { [math]::Round($cnt3/$total*100,1) } else { 0 }
                $hex3 = if ($colorMap.ContainsKey($lbl3)) { $colorMap[$lbl3] } else { "#888" }
                $brush3 = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString($hex3))
                $tile3 = New-Object System.Windows.Controls.Border
                $tile3.Background = $brush3; $tile3.CornerRadius = [System.Windows.CornerRadius]8
                $tile3.Margin = [System.Windows.Thickness]4; $tile3.Padding = [System.Windows.Thickness]"12,8,12,8"
                $tile3.MinWidth = 120; $tile3.Cursor = [System.Windows.Input.Cursors]::Hand; $tile3.Tag = $lbl3
                $sp3 = New-Object System.Windows.Controls.StackPanel
                $t1c = New-Object System.Windows.Controls.TextBlock; $t1c.Text = $lbl3; $t1c.Foreground = [System.Windows.Media.Brushes]::White; $t1c.FontSize = 11
                $t2c = New-Object System.Windows.Controls.TextBlock; $t2c.Text = "$cnt3 ($pct3%)"; $t2c.Foreground = [System.Windows.Media.Brushes]::White; $t2c.FontSize = 16; $t2c.FontWeight = [System.Windows.FontWeights]::Bold
                [void]$sp3.Children.Add($t1c); [void]$sp3.Children.Add($t2c); $tile3.Child = $sp3
                $tile3.Add_MouseLeftButtonUp({
                    param($src,$e3)
                    $bLabel3 = $src.Tag
                    if ($Script:HeatmapBucketComps -and $Script:HeatmapBucketComps.ContainsKey($bLabel3)) {
                        $gridComputerHeatmapDetail.ItemsSource = [object[]]@($Script:HeatmapBucketComps[$bLabel3])
                        $lblComputerHeatmapDetailTitle.Text = "$bLabel3  ($($Script:HeatmapBucketComps[$bLabel3].Count) computers)"
                        $borderComputerHeatmapDetail.Visibility = [System.Windows.Visibility]::Visible
                    }
                })
                [void]$icComputerHeatmap.Items.Add($tile3)
            }
        })
        $lblComputerHeatmapInfo.Text = "Total enabled: $total | $(Get-Date -Format 'HH:mm:ss')"
        Set-Status "Computer heatmap loaded." 100
    } catch { Set-Status "Error loading computer heatmap." 0; Write-ADLog "ERROR Load-ComputerHeatmap: $($_.Exception.Message)" "ERROR" }
}
$btnComputerHeatmap.Add_Click({
    if ($panelComputerHeatmap.Visibility -eq [System.Windows.Visibility]::Collapsed) {
        $panelComputerHeatmap.Visibility = [System.Windows.Visibility]::Visible
        Load-ComputerHeatmap
    } else {
        $panelComputerHeatmap.Visibility = [System.Windows.Visibility]::Collapsed
    }
})
$btnComputerHeatmapDetailClose.Add_Click({ $borderComputerHeatmapDetail.Visibility = [System.Windows.Visibility]::Collapsed })

# ── NETWORK STATUS ────────────────────────────────────────────────────────────

# ── NET STATUS: Get computers from AD ────────────────────────────────────────
$Script:NetComputers = @()
function Get-NetComputers {
    if (-not (Ensure-ADModule)) { return }
    try {
        Set-Status "Loading computers from AD..." 20
        $all = Get-ADComputer -Filter { Enabled -eq $true } -Properties DNSHostName,OperatingSystem,LastLogonDate,IPv4Address | Sort-Object Name
        $Script:NetComputers = @($all)
        $lstNetComputers.Children.Clear()
        foreach ($comp in $all) {
            $chk = New-Object System.Windows.Controls.CheckBox
            $chk.Content = "  $($comp.Name)  [$($comp.OperatingSystem)]"
            $chk.Tag = $comp
            $chk.IsChecked = $true
            $chk.FontSize = 12
            $chk.Margin = [System.Windows.Thickness]"2,1,2,1"
            $chk.ToolTip = "IP: $($comp.IPv4Address)   DNS: $($comp.DNSHostName)"
            [void]$lstNetComputers.Children.Add($chk)
        }
        $borderNetComputers.Visibility = [System.Windows.Visibility]::Visible
        $lblNetCompCount.Text = "Computers from AD: $($all.Count) total - check to include in scan"
        Set-Status "Loaded $($all.Count) computers." 100
    } catch { Set-Status "Error loading computers." 0; Write-ADLog "ERROR Get-NetComputers: $($_.Exception.Message)" "ERROR" }
}

# ── NET STATUS: Parallel scan with RunspacePool ───────────────────────────────

# ── NET STATUS: Sequential scan in single background runspace ─────────────────

function Start-NetScan {
    if (-not (Ensure-ADModule)) { return }
    $Script:NetScanCancel = $false
    $btnNetScan.IsEnabled = $false
    $btnNetStop.IsEnabled = $true
    $btnNetStop.Visibility = [System.Windows.Visibility]::Visible

    $timeout = 30; [int]::TryParse($txtNetTimeout.Text.Trim(), [ref]$timeout) | Out-Null
    $retries = 0;  [int]::TryParse($txtNetRetries.Text.Trim(), [ref]$retries) | Out-Null
    $threads = 20; [int]::TryParse($txtNetThreads.Text.Trim(), [ref]$threads) | Out-Null
    $threads = [math]::Max(1, [math]::Min($threads, 50))
    $onlineOnly = ($chkNetOnlineOnly.IsChecked -eq $true)
    $useWMI     = ($chkNetWMI.IsChecked        -eq $true)
    $usePSR     = ($chkNetPSRemoting.IsChecked -eq $true)
    $useRemReg  = ($chkNetRemoteReg.IsChecked  -eq $true)
    $discMethod = switch($cmbNetMethod.SelectedIndex){0{"Ping"} 1{"TCP445"} 2{"TCP88"} 3{"TCP389"} 4{"TCP3389"} 5{"Multi"} default{"Multi"}}

    $selectedComps = @()
    if ($lstNetComputers.Children.Count -gt 0) {
        foreach ($chk in $lstNetComputers.Children) {
            if ($chk.IsChecked -eq $true) { $selectedComps += $chk.Tag }
        }
    }
    if ($selectedComps.Count -eq 0) {
        if ($Script:NetComputers.Count -gt 0) { $selectedComps = $Script:NetComputers }
        else { try { $selectedComps = @(Get-ADComputer -Filter { Enabled -eq $true } -Properties DNSHostName,OperatingSystem,LastLogonDate,IPv4Address | Sort-Object Name) } catch {} }
    }

    # Convert to plain hashtables - safe across runspace boundaries
    $__comps = @($selectedComps | ForEach-Object {
        $ipv4 = if($_.IPv4Address){[string]$_.IPv4Address}else{''}
        $dns  = if($_.DNSHostName){[string]$_.DNSHostName}else{[string]$_.Name}
        # Try DNS resolve for IPv6
        $ipv6 = ''
        try {
            $addrs = [System.Net.Dns]::GetHostAddresses($dns) | Where-Object { $_.AddressFamily -eq 'InterNetworkV6' -and $_.ToString() -ne '::1' }
            if ($addrs) { $ipv6 = ($addrs | Select-Object -First 1).ToString() }
        } catch {}
        @{ Name=[string]$_.Name; DNS=$dns
           OS=if($_.OperatingSystem){[string]$_.OperatingSystem}else{''}
           LL=$_.LastLogonDate; IP=$ipv4; IPv6=$ipv6 }
    })

    $__grid=$gridNetStatus;$__lbl=$lblNetProgress;$__cnt=$lblNetCount
    $__btnStart=$btnNetScan;$__btnStop=$btnNetStop
    $__cancelRef=[ref]$Script:NetScanCancel;$__pb=$Global:pbMain
    $__timeout=[math]::Max(10,[math]::Min($timeout,10000))
    $__retries=[math]::Max(0,[math]::Min($retries,5))
    $__threads=$threads;$__onlineOnly=$onlineOnly
    $__useWMI=$useWMI;$__usePSR=$usePSR;$__useRemReg=$useRemReg;$__discMethod=$discMethod

    # Worker script (per computer) - runs in RunspacePool thread
    $workerStr = @'
param($comp,$timeout,$retries,$useWMI,$usePSR,$useRemReg,$discMethod)
function ping1 { param($t,$ms,$r) for($i=0;$i -le $r;$i++){try{$x=(New-Object System.Net.NetworkInformation.Ping).Send($t,$ms);if($x.Status -eq 'Success'){return $x}}catch{}};return $null }
function tcpport { param($t,$port,$ms) try{$tc=New-Object System.Net.Sockets.TcpClient;$ar=$tc.BeginConnect($t,$port,$null,$null);$ok=$ar.AsyncWaitHandle.WaitOne($ms,$false);$tc.Close();return $ok}catch{return $false} }
$nm=$comp.Name;$dn=$comp.DNS
$reply=$null;$online=$false;$ip=$comp.IP;$ipv6=$comp.IPv6;$rtt=''
$tryPing=($discMethod -eq 'Ping' -or $discMethod -eq 'Multi')
if($tryPing){
    $reply=ping1 $dn $timeout $retries;if(-not $reply){$reply=ping1 $nm $timeout $retries}
    if($reply){
    $online=$true
    $resolvedAddr = $reply.Address.ToString()
    if($resolvedAddr -eq '::1' -or $resolvedAddr -match '^fe80'){
        # Ping returned IPv6 loopback/link-local - use AD IPv4 if available
        if($comp.IP){ $ip=$comp.IP }else{ $ip='' }
        if(-not $ipv6 -and $resolvedAddr -ne '::1'){ $ipv6=$resolvedAddr }
    } else {
        $ip=$resolvedAddr
    }
    $rtt="$($reply.RoundtripTime) ms"
}
}
if(-not $online -and $discMethod -ne 'Ping'){
    $ports=switch($discMethod){'TCP445'{@(445)}'TCP88'{@(88)}'TCP389'{@(389)}'TCP3389'{@(3389)}'Multi'{@(445,88,389,3389)}default{@(445)}}
    foreach($p in $ports){$ok=tcpport $dn $p $timeout;if(-not $ok){$ok=tcpport $nm $p $timeout};if($ok){$online=$true;$rtt="TCP $p OK";break}}
}
$row=[ordered]@{Status=if($online){'Online'}else{'Offline'};Name=$nm;IP=$ip;RTT=$rtt;Port445='';Port88='';Port389='';OS=$comp.OS;LastLogon=$comp.LL;LastUserLogon='';Uptime='';FreeRAM='';FreeDisk='';'FreeDisk%'='';DNSHost=$dn}
if($online){
    $row['Port445']=if(tcpport $dn 445 500){'Open'}elseif(tcpport $nm 445 500){'Open'}else{''}
    $row['Port88'] =if(tcpport $dn 88  300){'Open'}elseif(tcpport $nm 88  300){'Open'}else{''}
    $row['Port389']=if(tcpport $dn 389 300){'Open'}elseif(tcpport $nm 389 300){'Open'}else{''}
    if($useRemReg){try{$reg=[Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey('LocalMachine',$nm);$k=$reg.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI');if($k){$lu=$k.GetValue('LastLoggedOnUser');if($lu){$row['LastUserLogon']=$lu -replace '^.*\\',''};$k.Close()};$reg.Close()}catch{}}
    if($useWMI){try{$o=Get-CimInstance Win32_OperatingSystem -ComputerName $nm -EA Stop;$row['Uptime']=if($o.LastBootUpTime){"$([math]::Round(((Get-Date)-$o.LastBootUpTime).TotalDays,1))d"}else{''};$row['FreeRAM']="$([math]::Round($o.FreePhysicalMemory/1MB,1)) / $([math]::Round($o.TotalVisibleMemorySize/1MB,1)) GB";$dk=Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ComputerName $nm -EA Stop;$row['FreeDisk']=($dk|%{"$($_.DeviceID) $([math]::Round($_.FreeSpace/1GB,1))/$([math]::Round($_.Size/1GB,1))GB"})-join'  ';$row['FreeDisk%']=($dk|Where-Object{$_.Size -gt 0}|%{"$($_.DeviceID) $([math]::Round((1-$_.FreeSpace/$_.Size)*100,0))%"})-join' ';if(-not $row['LastUserLogon']){try{$cs=Get-CimInstance Win32_ComputerSystem -ComputerName $nm -EA Stop;if($cs.UserName){$row['LastUserLogon']=$cs.UserName -replace '^.*\\',''}}catch{}}}catch{$row['FreeRAM']='WMI err';$row['FreeDisk']='WMI err'}}
    if($usePSR -and(-not $useWMI -or $row['FreeRAM'] -eq 'WMI err')){try{$d=Invoke-Command -ComputerName $nm -EA Stop -ScriptBlock{$o=Get-CimInstance Win32_OperatingSystem;$dk=Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3';$lu=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI' -EA SilentlyContinue).LastLoggedOnUser;@{Up=if($o.LastBootUpTime){[math]::Round(((Get-Date)-$o.LastBootUpTime).TotalDays,1)}else{0};Fr=[math]::Round($o.FreePhysicalMemory/1MB,1);Tot=[math]::Round($o.TotalVisibleMemorySize/1MB,1);Dk=($dk|%{"$($_.DeviceID) $([math]::Round($_.FreeSpace/1GB,1))/$([math]::Round($_.Size/1GB,1))GB"})-join'  ';DkP=($dk|Where-Object{$_.Size -gt 0}|%{"$($_.DeviceID) $([math]::Round((1-$_.FreeSpace/$_.Size)*100,0))%"})-join' ';Lu=$lu}};$row['Uptime']="$($d.Up)d";$row['FreeRAM']="$($d.Fr) / $($d.Tot) GB";$row['FreeDisk']=$d.Dk;if($d.DkP){$row['FreeDisk%']=$d.DkP};if(-not $row['LastUserLogon'] -and $d.Lu){$row['LastUserLogon']=$d.Lu -replace '^.*\\',''}}catch{if($row['FreeRAM'] -eq 'WMI err'){$row['FreeRAM']='PSR err'}}}
}
return [PSCustomObject]$row
'@

    # Orchestrator - manages RunspacePool (MTA compatible)
    $orchStr = @'
param($grid,$lbl,$cnt,$btnStart,$btnStop,$cancelRef,$pb,$comps,$timeout,$retries,$threads,$onlineOnly,$useWMI,$usePSR,$useRemReg,$discMethod,$workerStr)
function ui{param($ctrl,$sb)try{$ctrl.Dispatcher.Invoke([System.Action]$sb)}catch{}}
$iss=[System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$pool=[System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1,$threads,$iss,$Host)
$pool.ApartmentState='MTA'
$pool.Open()
$jobs=[System.Collections.Generic.List[hashtable]]::new()
foreach($c in $comps){
    if($cancelRef.Value){break}
    $ps=[System.Management.Automation.PowerShell]::Create()
    $ps.RunspacePool=$pool
    [void]$ps.AddScript($workerStr).AddArgument($c).AddArgument($timeout).AddArgument($retries).AddArgument($useWMI).AddArgument($usePSR).AddArgument($useRemReg).AddArgument($discMethod)
    [void]$jobs.Add(@{PS=$ps;Handle=$ps.BeginInvoke();Name=$c.Name})
}
$total=$jobs.Count
$results=[System.Collections.Generic.List[object]]::new()
$done=0
while($done -lt $jobs.Count){
    if($cancelRef.Value){break}
    $finished=@($jobs|Where-Object{$_.Handle.IsCompleted -eq $true})
    foreach($j in $finished){
        try{
            $r=$j.PS.EndInvoke($j.Handle)
            if($r -and $r.Count -gt 0 -and $r[0]){
                if(-not $onlineOnly -or $r[0].Status -eq 'Online'){[void]$results.Add($r[0])}
            }
        }catch{}
        $j.PS.Dispose()
        [void]$jobs.Remove($j)
        $done++
        $pct=[int](($done/$total)*100)
        $snap=[object[]]@($results|%{$_})
        ui $lbl {$lbl.Text="[$done/$total] ($pct%) complete..."}
        try{ui $pb {$pb.Value=$pct}}catch{}
        ui $grid {$grid.ItemsSource=$snap}
    }
    if($finished.Count -eq 0){Start-Sleep -Milliseconds 100}
}
foreach($j in $jobs){try{$j.PS.EndInvoke($j.Handle)}catch{};$j.PS.Dispose()}
$pool.Close();$pool.Dispose()
$all=[object[]]@($results|Sort-Object Name)
$onC=($results|Where-Object{$_.Status -eq 'Online'}).Count
$offC=($results|Where-Object{$_.Status -eq 'Offline'}).Count
ui $grid    {$grid.ItemsSource=$all}
ui $cnt     {$cnt.Text="Online: $onC  |  Offline: $offC  |  Total: $($results.Count)"}
ui $lbl     {$lbl.Text=if($cancelRef.Value){'Scan stopped.'}else{"Scan complete. Online:$onC Offline:$offC"}}
try{ui $pb  {$pb.Value=100}}catch{}
ui $btnStart{$btnStart.IsEnabled=$true}
ui $btnStop {$btnStop.Visibility=[System.Windows.Visibility]::Collapsed;$btnStop.IsEnabled=$true}
'@
    $rs=[System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState='STA';$rs.ThreadOptions='ReuseThread';$rs.Open()
    $ps2=[System.Management.Automation.PowerShell]::Create()
    $ps2.Runspace=$rs
    [void]$ps2.AddScript($orchStr).AddArgument($__grid).AddArgument($__lbl).AddArgument($__cnt).AddArgument($__btnStart).AddArgument($__btnStop).AddArgument($__cancelRef).AddArgument($__pb).AddArgument($__comps).AddArgument($__timeout).AddArgument($__retries).AddArgument($__threads).AddArgument($__onlineOnly).AddArgument($__useWMI).AddArgument($__usePSR).AddArgument($__useRemReg).AddArgument($__discMethod).AddArgument($workerStr)
    $handle=$ps2.BeginInvoke()
    $tmr=New-Object System.Windows.Threading.DispatcherTimer
    $tmr.Interval=[TimeSpan]::FromMilliseconds(500)
    $tmr.Add_Tick({
        if($handle.IsCompleted){
            $tmr.Stop()
            try{foreach($e in $ps2.Streams.Error){Write-Out "NetScan ERR: $e" "ERROR"};$ps2.EndInvoke($handle)}catch{}
            $ps2.Dispose();$rs.Dispose()
        }
    })
    $tmr.Start()
}

$btnNetScan.Add_Click({ Start-NetScan })
$btnNetGetComputers.Add_Click({ Get-NetComputers })
$btnNetSelectAll.Add_Click({ foreach($chk in $lstNetComputers.Children){$chk.IsChecked=$true} })
$btnNetSelectNone.Add_Click({ foreach($chk in $lstNetComputers.Children){$chk.IsChecked=$false} })
$btnNetStop.Add_Click({ $Script:NetScanCancel = $true; $btnNetStop.IsEnabled = $false })
$btnNetExport.Add_Click({ Export-ToCSV -Data $gridNetStatus.ItemsSource -DefaultName "AD_NetworkStatus.csv" })
$ctxNetCopyCell.Add_Click({ $v = Get-GridCellValue -grid $gridNetStatus; if ($v) { [System.Windows.Clipboard]::SetText("$v") } })
$ctxNetCopyRow.Add_Click({  $v = Get-GridRowValue  -grid $gridNetStatus; if ($v) { [System.Windows.Clipboard]::SetText($v) } })
$ctxNetPing.Add_Click({
    $sel = $gridNetStatus.SelectedItem
    if (-not $sel) { return }
    $t = if ($sel.DNSHost) { $sel.DNSHost } else { $sel.Name }
    Start-Process "cmd" -ArgumentList "/k ping -t $t" -ErrorAction SilentlyContinue
})
$ctxNetRDP.Add_Click({
    $sel = $gridNetStatus.SelectedItem
    if (-not $sel) { return }
    $t = if ($sel.IP) { $sel.IP } elseif ($sel.DNSHost) { $sel.DNSHost } else { $sel.Name }
    Start-Process "mstsc" -ArgumentList "/v:$t" -ErrorAction SilentlyContinue
})


#region ── STARTUP ────────────────────────────────────────────────────────────
$Script:SortHandler = {
    param($sender, $e)
    $e.Handled = $true
    $grid = $sender
    $col  = $e.Column
    if (-not $grid -or -not $col) { return }
    $prop = $col.SortMemberPath
    if ([string]::IsNullOrWhiteSpace($prop)) { $prop = [string]$col.Header }
    if ([string]::IsNullOrWhiteSpace($prop)) { return }
    $items = @($grid.ItemsSource)
    if ($items.Count -eq 0) { return }
    $asc  = [System.ComponentModel.ListSortDirection]::Ascending
    $desc = [System.ComponentModel.ListSortDirection]::Descending
    $dir  = if ($col.SortDirection -eq $asc) { $desc } else { $asc }
    foreach ($c2 in $grid.Columns) { $c2.SortDirection = $null }
    $col.SortDirection = $dir
    $p = $prop
    $sorted = if ($dir -eq $asc) {
        $items | Sort-Object -Property @{ Expression = {
            $v = $_.PSObject.Properties[$p].Value
            if ($null -eq $v) { return $null }
            if ($v -is [datetime]) { return $v }
            if ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) { return $v }
            $num = 0.0
            if ([double]::TryParse(($v -replace '[^0-9,\.\-]','').Replace(',','.'), [ref]$num)) { return $num }
            return [string]$v
        } }
    } else {
        $items | Sort-Object -Descending -Property @{ Expression = {
            $v = $_.PSObject.Properties[$p].Value
            if ($null -eq $v) { return $null }
            if ($v -is [datetime]) { return $v }
            if ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) { return $v }
            $num = 0.0
            if ([double]::TryParse(($v -replace '[^0-9,\.\-]','').Replace(',','.'), [ref]$num)) { return $num }
            return [string]$v
        } }
    }
    $grid.ItemsSource = [object[]]@($sorted)
    if ($grid -eq $gridUsers) {
        $Script:UserCV = [System.Windows.Data.CollectionViewSource]::GetDefaultView($gridUsers.ItemsSource)
        if ($txtUserLiveFilter -and -not [string]::IsNullOrWhiteSpace($txtUserLiveFilter.Text)) {
            $ft = $txtUserLiveFilter.Text.Trim()
            $Script:UserCV.Filter = [Predicate[object]]{
                param($item)
                $item.Username    -like "*$ft*" -or $item.DisplayName -like "*$ft*" -or
                $item.Email       -like "*$ft*" -or $item.Department  -like "*$ft*" -or
                $item.Title       -like "*$ft*"
            }
            $Script:UserCV.Refresh()
        }
    }
}

function Enable-ADGridSorting {
    param([System.Windows.Controls.DataGrid[]]$Grids)
    $autoGenHandler = {
        param($s, $e)
        if ($e.Column -and $e.Column.Header) {
            $e.Column.SortMemberPath = [string]$e.Column.Header
            $e.Column.CanUserSort = $true
        }
    }
    foreach ($g in $Grids) {
        if (-not $g) { continue }
        try { $g.CanUserSortColumns = $true } catch {}
        try { $g.Add_Sorting($Script:SortHandler) } catch {}
        try { $g.Add_AutoGeneratingColumn($autoGenHandler) } catch {}
        try {
            foreach ($col in $g.Columns) {
                if ([string]::IsNullOrWhiteSpace($col.SortMemberPath) -and $col.Header) {
                    $col.SortMemberPath = [string]$col.Header
                }
                $col.CanUserSort = $true
            }
        } catch {}
    }
}

$Window.Add_Loaded({
    Write-ADLog "AD Manager v$($Script:AppVersion) started on $env:COMPUTERNAME by $env:USERNAME"
    Load-SystemInfo
    Load-DomainInfo
    Enable-ADGridSorting -Grids @(
        $gridNetStatus,$gridUsers,$gridGroups,$gridComputers,$gridShares,$gridPerms,
        $gridDisk,$gridRamSticks,$gridPhysDisk,$gridNetAdapters,$gridServices,$gridStartup,$gridProcs,
        $gridMemberOf,$gridGPOs,$gridGPOLinks,$gridDCs,$gridHeatmapDetail,
        $gridComputerHeatmapDetail,$gridUsersHeatmapDetail
    )
})


$Window.ShowDialog() | Out-Null
#endregion
