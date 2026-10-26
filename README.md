# 截图入库

菜单栏里的 macOS 截图工具。按 F2 框选屏幕，框选条上只有三个按钮：保存、入库、取消。

保存把 PNG 放进剪贴板。入库关掉选区，在后台排队：智谱看图表格台词，再写进飞书多维表格「截图库」。成功后有系统通知，标题是当天的「18日第 1 张」这种序号。上传失败的图进失败库，可以之后从菜单重传。

粉丝清单也放在这个仓库里，每天更新，只公开昵称和头像。见 [followers/README.md](followers/README.md)。

## 仓库里有什么

| 路径 | 内容 |
| --- | --- |
| `Sources/` | 菜单栏应用 |
| `Helper/` | 单独负责截屏的小程序源码 |
| `build.sh` | 编译并签名主应用 |
| `followers/` | 每日粉丝清单和更新脚本 |
| `.github/workflows/update-followers.yml` | 每天北京时间 0 点跑清单 |

看图和写飞书的 Python 还在作者本机的工作区里（`scripts/read_and_ingest_screenshot.py`）。已安装的应用会沿用那台电脑上的路径。这个目录不包含飞书密钥、智谱密钥、抖音 Cookie、签名证书私钥。

## 本机怎么用

需要 macOS 14、Xcode 命令行工具里的 `swiftc`。

```bash
./build.sh
```

本机钥匙串里如果有名为 `Screenshot Ingest Local` 的代码签名证书，脚本会用它签名。没有这张证书时，会改用临时签名，系统的屏幕录制权限可能对不上，需要在「系统设置 → 隐私与安全性 → 录屏与系统录音」里重新打开一次。

装好后的应用在 `~/Applications/截图入库.app`。登录时由 `~/Library/LaunchAgents/com.chenglong.screenshot-ingest.plist` 拉起。截屏由另一个已经签过名的 `CaptureHelper` 完成，平时不要重新编译或重新签名它，否则录屏权限会失效。

如果 F2 仍在调屏幕亮度，到「系统设置 → 键盘」打开「将 F1、F2 等键用作标准功能键」。

入库用到的环境变量见 [.env.example](.env.example)。填好的 `.env` 不要提交。

失败的图默认在 `~/Library/Application Support/截图入库/failed/`。菜单里有「重传失败库」和「打开失败库」。

## 每日粉丝清单

仓库是公开的，清单里的昵称和头像任何人都能看到。不写抖音号，也不写账号 id。

第一次跑起来之前，在 GitHub 仓库的 Settings → Secrets and variables → Actions 里添加：

| 密钥 | 内容 |
| --- | --- |
| `DOUYIN_COOKIE` | 浏览器登录 douyin.com 之后，从开发者工具复制的整段 Cookie，里面要有 `sessionid` |
| `DOUYIN_SEC_UID` | 自己主页网址里 `MS4wLjAB` 开头的那一段 |
| `DOUYIN_UNIQUE_ID` | 可选。没有 sec_uid 时用抖音号 |
| `DOUYIN_FOLLOWER_LIMIT` | 可选。单日最多人数，不填则按 2000 |

然后到 Actions 里手动运行「每日粉丝清单」。成功后会提交：

- `followers/latest.md`：当天名单，头像直接显示在 GitHub 上
- `followers/days/日期.md`：这一天的清单，按天留下
- `followers/avatars/`：头像文件，同一位粉丝下次不会重复下载

还要在 Settings → Actions → General → Workflow permissions 里允许 Actions 写入仓库，定时任务才能把清单推回来。

抖音经常拒绝 GitHub 云主机的访问。如果日志里是空内容或未登录以外的拒绝，把 workflow 里的 `runs-on` 改成这台 Mac 上的 self-hosted runner，Cookie 仍然只放在密钥里。

作者这台电脑上原来保存的抖音 Cookie 已经是未登录状态，所以上传前要换一份新的，放进密钥，不要放进仓库文件。

## 不要提交的东西

- `.env`、Cookie、飞书和智谱的密钥
- `build/` 里编译出来的应用
- 签名用的 `.pem`、`.p12`、`.cer`
- 失败库里的截图

## 许可

[MIT](LICENSE)
