object frmMain: TfrmMain
  Left = 0
  Top = 0
  Caption = 'mxLoreMCP Server'
  ClientHeight = 450
  ClientWidth = 600
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poScreenCenter
  OnCloseQuery = FormCloseQuery
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  OnShow = FormShow
  object pnlStatus: TPanel
    Left = 0
    Top = 0
    Width = 600
    Height = 80
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 0
    object lblStatus: TLabel
      Left = 16
      Top = 12
      Width = 58
      Height = 20
      Caption = 'Stopped'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clRed
      Font.Height = -15
      Font.Name = 'Segoe UI'
      Font.Style = [fsBold]
      ParentFont = False
    end
    object lblPorts: TLabel
      Left = 16
      Top = 36
      Width = 30
      Height = 15
      Caption = 'Ports:'
    end
    object lblUptime: TLabel
      Left = 300
      Top = 12
      Width = 81
      Height = 15
      Caption = 'Uptime: 0:00:00'
    end
    object lblRequests: TLabel
      Left = 300
      Top = 36
      Width = 59
      Height = 15
      Caption = 'Requests: 0'
    end
  end
  object pnlButtons: TPanel
    Left = 0
    Top = 80
    Width = 600
    Height = 36
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 1
    object btnStartStop: TButton
      Left = 16
      Top = 4
      Width = 100
      Height = 28
      Caption = 'Start'
      TabOrder = 0
      OnClick = btnStartStopClick
    end
  end
  object reLog: TRichEdit
    Left = 0
    Top = 116
    Width = 600
    Height = 334
    Align = alClient
    Font.Charset = ANSI_CHARSET
    Font.Color = clWindowText
    Font.Height = -11
    Font.Name = 'Consolas'
    Font.Style = []
    ParentFont = False
    ReadOnly = True
    ScrollBars = ssVertical
    TabOrder = 2
  end
  object tmrUptime: TTimer
    Enabled = False
    OnTimer = tmrUptimeTimer
    Left = 520
    Top = 16
  end
  object tmrLogFlush: TTimer
    Interval = 200
    OnTimer = tmrLogFlushTimer
    Left = 520
    Top = 56
  end
  object TrayIcon: TTrayIcon
    Hint = 'mxLoreMCP Server'
    PopupMenu = pmTray
    Visible = True
    OnDblClick = TrayIconDblClick
    Left = 464
    Top = 16
  end
  object pmTray: TPopupMenu
    Left = 464
    Top = 56
    object miShow: TMenuItem
      Caption = 'Anzeigen'
      OnClick = miShowClick
    end
    object miStartStop: TMenuItem
      Caption = 'Start/Stop'
      OnClick = miStartStopClick
    end
    object N1: TMenuItem
      Caption = '-'
    end
    object miExit: TMenuItem
      Caption = 'Beenden'
      OnClick = miExitClick
    end
  end
end
