# sing-box-easy-deploy

一个支持nat的 sing-box 多协议一键安装与管理脚本。

支持 Shadowsocks、Hysteria2、VLESS Reality，以及 VLESS Reality 链式中转。支持nat

## 一键安装

请先进入 root 用户：

```bash
sudo -i
```

然后运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MrlixiangWE/sing-box-vless-easy-deploy/main/install-singbox-yyds2.sh)
```
**或使用内存分页版本**：仅支持vless+reality，经过内存优化，可以在内存大于34MB的机器上运行：
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MrlixiangWE/sing-box-vless-easy-deploy/main/install-singbox-yyds3.sh)
```


安装过程中可以自定义节点名称、端口和密码。直接按回车时，脚本会自动生成随机配置。

安装完成后，终端会输出：

* Shadowsocks 节点链接
* Hysteria2 节点链接
* VLESS Reality 节点链接
* 配置文件位置
* 服务管理命令

## 功能介绍

### 1. 多协议一键部署

一次安装即可同时部署：

1. Shadowsocks 2022
2. Hysteria2
3. VLESS Reality

安装完成后会自动生成客户端导入链接。

### 2. 自动配置系统服务

脚本会自动创建并启动 sing-box 服务，同时设置开机自启。

支持：

* Debian
* Ubuntu
* CentOS
* RHEL
* Fedora
* Alpine Linux

### 3. `sb` 管理面板

安装完成后，在服务器中输入：

```bash
sb
```

即可打开 sing-box 管理面板。

管理面板支持：

1. 查看 SS、HY2、Reality 节点链接
2. 查看配置文件位置
3. 编辑 sing-box 配置
4. 重置 SS 端口和密码
5. 重置 HY2 端口和密码
6. 重置 Reality 端口和 UUID
7. 启动、停止或重启服务
8. 查看服务运行状态
9. 更新 sing-box
10. 搭建 VLESS Reality 中转
11. 查看、重置或关闭中转
12. 卸载 sing-box

### 4. 自动生成节点信息

脚本会自动生成：

* 随机端口
* SS 和 HY2 密码
* VLESS UUID
* Reality 公钥与私钥
* Reality Short ID
* Hysteria2 自签名证书
* 客户端导入链接


## 搭建链式 VLESS Reality

链式 VLESS 适合使用两台服务器：

```text
客户端
   ↓
中转机
   ↓
落地机
   ↓
目标网站
```

其中：

* **中转机**：客户端直接连接的服务器
* **落地机**：最终访问互联网的服务器

客户端只需要导入中转机生成的 VLESS Reality 链接。

### 第一步：配置落地机

先在落地机上安装本项目：

```bash
sudo -i
bash <(curl -fsSL https://raw.githubusercontent.com/MrlixiangWE/sing-box-vless-easy-deploy/main/install-singbox-yyds2.sh)
```

安装完成后输入：

```bash
sb
```

选择：

```text
1) 查看三协议链接
```

复制落地机的完整 VLESS Reality 链接，例如：

```text
vless://UUID@落地机IP:端口?encryption=none&flow=xtls-rprx-vision&security=reality&sni=example.com&fp=chrome&pbk=公钥&sid=ShortID#reality
```

需要复制完整链接，包括 `pbk`、`sid`、`sni` 等参数。

### 第二步：配置中转机

在中转机上安装本项目：

```bash
sudo -i
bash <(curl -fsSL https://raw.githubusercontent.com/MrlixiangWE/sing-box-vless-easy-deploy/main/install-singbox-yyds2.sh)
```

安装完成后输入：

```bash
sb
```

选择：

```text
12) 搭建/更新 VLESS Reality 中转
```

然后按照提示输入：

1. 落地机的完整 VLESS Reality 链接
2. 中转机监听端口，留空则随机生成
3. 中转节点名称，留空则使用 `relay`
4. 中转入口 Reality SNI，通常可以直接回车

脚本会自动完成：

* 解析落地机地址和端口
* 读取落地机 UUID
* 读取落地机 Reality 公钥
* 读取 SNI 和 Short ID
* 创建中转机 VLESS Reality 入站
* 创建指向落地机的 VLESS Reality 出站
* 添加中转路由
* 校验配置并重启 sing-box

### 第三步：获取中转节点链接

配置完成后，脚本会直接输出中转节点链接。

也可以重新输入：

```bash
sb
```

选择：

```text
13) 查看 VLESS Reality 中转
```

将输出的 VLESS Reality 链接导入客户端即可。

最终流量路径为：

```text
客户端 → 中转机 VLESS Reality → 落地机 VLESS Reality → Internet
```

### 中转管理

输入：

```bash
sb
```

可以使用以下选项：

```text
12) 搭建/更新 VLESS Reality 中转
13) 查看 VLESS Reality 中转
14) 重置 VLESS Reality 中转入口
15) 关闭 VLESS Reality 中转
```

重置中转入口时，可以：

* 修改中转监听端口
* 保留现有 UUID 和 Reality 密钥
* 重新生成 UUID 和 Reality 密钥

关闭中转后，原始的 SS、HY2 和 VLESS Reality 节点不会被删除。


## 常用命令

打开管理面板：

```bash
sb
```


## 注意事项

1. 请确保服务器防火墙和云平台安全组已经放行对应端口。
2. Hysteria2 使用 UDP，请同时检查 UDP 端口是否放行。
3. VLESS Reality 中转目前只支持 Reality TCP 类型的目标链接。
4. 搭建中转时必须粘贴完整的 VLESS Reality 链接。
5. 目标链接必须包含 Reality 公钥参数 `pbk`。
6. 修改配置后可以运行 `sing-box check` 检查配置是否合法。
7. 请不要将服务器生成的 UUID、密码和节点链接公开提交到 GitHub。

## 卸载

输入：

```bash
sb
```

选择：

```text
17) 卸载 sing-box
```

按照提示确认即可。

## 免责声明

本项目仅用于网络技术研究、学习和个人服务器管理。

使用者应遵守所在国家或地区的法律法规。因不当使用本项目产生的任何后果，由使用者自行承担。

## 开源协议

本项目基于 [MIT License](LICENSE) 开源。

你可以自由地：

* 使用本项目
* 复制和修改代码
* 分发修改后的版本
* 用于个人或商业项目
* 将代码合并到其他项目中

使用或分发本项目时，需要保留原始版权声明和 MIT License 声明。

本项目按“原样”提供，作者不对软件的适用性、稳定性、安全性以及使用过程中产生的任何损失承担责任。

## 版本说明

当前开源版本：

```text
v1.0.0
```

版本号遵循以下规则：

* `v1.0.0`：首个公开稳定版本
* `v1.0.x`：问题修复和小范围调整
* `v1.x.0`：新增功能，保持基本兼容
* `vx.0.0`：存在较大的功能或使用方式变更

具体更新内容请查看 GitHub Releases 或提交记录。

## 第三方项目声明

本项目是基于 sing-box 开发的自动化部署与管理脚本，并非 sing-box 官方项目。

sing-box 的名称、程序及相关组件归其原作者和贡献者所有。使用本项目时，还应遵守 sing-box 及其他第三方组件各自的开源许可证。

本项目与 sing-box 官方开发团队不存在隶属、授权或担保关系。
