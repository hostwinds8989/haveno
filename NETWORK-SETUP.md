# Haveno 网络自建运行手册

这份说明描述如何把这套源码构建成**属于你自己的** Haveno 网络（门罗币主网），用于演示和测试。
本仓库已经按下方清单预先改好了「网络身份定制」相关的所有代码。

## 已完成的源码改动

- `common/src/main/java/haveno/common/app/Version.java`
  - `P2P_NETWORK_VERSION` 由 `"A"` 改为 `"B"`（与其他网络隔离）。
- `core/src/main/java/haveno/core/app/HavenoExecutable.java`
  - `DEFAULT_APP_NAME` 由 `"Haveno"` 改为 `"HavenoX"`（避免与官方 Haveno 共用数据目录）。
- `Makefile`
  - 四处 `--appName=Haveno` 改为 `--appName=HavenoX`（与 `DEFAULT_APP_NAME` 保持一致）。
- `common/src/main/java/haveno/common/app/DevEnv.java`
  - 新增常量 `NETWORK_PUBLIC_KEY`，目前是占位符 `PASTE_PUBLIC_KEY_HEX_HERE`，**需要你替换**（见下方第 2 步）。
- 以下四个文件的主网 `XMR_MAINNET` 分支由「空列表」改为引用 `DevEnv.NETWORK_PUBLIC_KEY`：
  - `core/src/main/java/haveno/core/alert/AlertManager.java`
  - `core/src/main/java/haveno/core/filter/FilterManager.java`
  - `core/src/main/java/haveno/core/alert/PrivateNotificationManager.java`
  - `core/src/main/java/haveno/core/support/dispute/arbitration/arbitrator/ArbitratorManager.java`（并补了 `DevEnv` import）
- `core/src/main/java/haveno/core/trade/HavenoUtils.java`
  - `RELEASE_DATE` 设为 `"21-11-2026 00:00:00"`（网络发布日期，可按需修改）。
  - 交易手续费沿用默认：`ARBITRATOR_ASSIGNS_TRADE_FEE_ADDRESS = true`（仲裁员收取到自己的钱包）。
    若要集中收取到单个地址，把该值改为 `false` 并在 `getGlobalTradeFeeAddress()` 的 `XMR_MAINNET` 分支填入 XMR 地址。
- 下载链接三处由 `https://haveno.exchange/downloads` 改为占位 `https://havenoexample.com/downloads`（部署前改成你的真实地址）：
  - `desktop/.../downloadupdate/HavenoInstaller.java`
  - `desktop/.../overlays/windows/DisplayAlertMessageWindow.java`
  - `desktop/.../account/content/notifications/MobileNotificationsView.java`
- `core/src/main/resources/xmr_mainnet.seednodes`
  - 已替换为注释模板，等待填入两个种子节点的洋葱地址（见下方第 5 步）。
- `core/src/main/java/haveno/core/provider/ProvidersRepository.java`
  - `DEFAULT_NODES` 加了注释，提示部署价格节点后把它的洋葱地址加到这里（可选）。

> 未改动但可选的项：fork 版本号（`Version.java` 的 `VERSION` 第三位等）、
> `HavenoInstaller.java` 的 `PINNED_SIGNING_KEY_FINGERPRINTS`（应用内更新签名校验）。

## 必须手动完成的唯一一步：生成并填入公钥

构建前需要一对公私钥。公钥要写进源码，私钥在注册仲裁员 / 添加过滤器时在界面里输入。

```
./gradlew :core:generateKeypairs
```

输出里每一组都包含公钥和私钥（演示网络可以所有角色都用第一组）。
把**第一组的公钥**替换进：

- `common/src/main/java/haveno/common/app/DevEnv.java` 的 `NETWORK_PUBLIC_KEY`

（部署脚本支持用环境变量自动替换，见下。）

## 两条运行路径

### 路径 A：Linux VPS 自动化脚本（推荐用于主网长期运行）

在 Ubuntu/Debian VPS 上（建议 >= 8 GB 内存、>= 4 核、>= 300 GB 磁盘，主网链约 230 GB+）：

```
chmod +x scripts/deployment/deploy-haveno-network.sh
export REPO_URL=https://github.com/<you>/<your-fork>.git
export API_PASSWORD=<strong-secret-without-spaces>

./scripts/deployment/deploy-haveno-network.sh install     # 装依赖、克隆、构建
./scripts/deployment/deploy-haveno-network.sh keypairs    # 生成密钥，得到公钥
# 把公钥写进环境变量，重新构建一次以写入源码：
export PUBLIC_KEY=<公钥>
./scripts/deployment/deploy-haveno-network.sh install

./scripts/deployment/deploy-haveno-network.sh monerod     # 启动门罗币节点（先等它同步完）
./scripts/deployment/deploy-haveno-network.sh seednodes   # 启动两个种子节点，打印洋葱地址
./scripts/deployment/deploy-haveno-network.sh arbitrator  # 启动仲裁员 daemon
./scripts/deployment/deploy-haveno-network.sh status      # 查看服务与同步进度
```

脚本会自动注册 systemd 服务：`haveno-monerod`、`haveno-seednode`、`haveno-seednode2`、`haveno-arbitrator`。

### 路径 B：本地手工运行（按上游指南）

1. 安装 Java 21 与构建工具（Ubuntu：`sudo apt install make wget git openjdk-21-jdk`）。
2. 克隆本仓库，`make clean && make`（或 `make skip-tests`）。
3. 新终端运行 `make monerod`，等它同步主网链。
4. 新终端运行 `make seednode`，记下打印的 `.onion` 地址（端口 1002）。
5. 新终端运行 `make seednode2`，记下 `.onion` 地址（端口 1003）。
6. 把两个地址写进 `core/src/main/resources/xmr_mainnet.seednodes`，例如：
   - `seednode1.onion:1002 (@seednode1)`
   - `seednode2.onion:1003 (@seednode2)`
7. `make skip-tests` 重新构建后，重启两个种子节点。
8. `make arbitrator-desktop-mainnet` 启动仲裁员界面；在 `Account` 页按 `ctrl+r` 输入私钥注册。
9. 在仲裁员（或任意实例）按 `ctrl+f`，输入开发者私钥，点 `Add Filter` 注册网络过滤器。
10. `make user1-desktop-mainnet` 和 `make user2-desktop-mainnet` 启动两个用户，测试与仲裁员的交易。
11. 把改好的整个仓库推送并分享，别人用同样配置构建后即可连入你的网络。

## 关键注意事项

- **磁盘与时间**：门罗币主网全节点约 230 GB+，首次同步可能要好几天；测试演示可改用 stagenet（链小、同步快）。
- **种子节点**：至少跑 2 个；避免所有种子节点同时离线，否则仲裁员和过滤器对象的注册信息会丢失，需要重新注册。
- **分享网络**：不能只给洋葱地址。其他人必须用**相同的公钥和相同配置**构建，才能连进你的网络，所以要分享整个 git 仓库。
- **仲裁员**：正式运行应放在 7x24 的 VPS 上；不要在不同仲裁员实例间复用同一对密钥。
- **下载链接**：把 `https://havenoexample.com/downloads` 替换成你真实的安装包下载地址后再对外分发。