# IDM Toolkit

> [!WARNING]
> 仅供技术学习研究，请在 24 小时内删除。请勿商用、请勿二次分发，请支持正版。

## 介绍

IDM 6.x 交互式授权工具，纯 PowerShell 单文件，零依赖。

自动提权、自动备份、自动回滚；未安装 IDM 时会自己从官网下载安装包、验签、静默安装。
9 处补丁点全部靠字节签名定位，任何一处对不上就拒绝写入。已实测 6.43 build 15。

## 使用方法

```powershell
irm https://raw.githubusercontent.com/yuukiiiii0228/idm-toolkit/main/idm.ps1 | iex
```
