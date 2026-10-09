# 用 GitHub Actions 持续尝试 Oracle A1

工作流文件：`.github/workflows/oci-a1-capacity.yml`

它每 5 分钟运行一次。GitHub 官方说明，定时工作流是尽力调度，最短间隔为 5 分钟，繁忙时可能延迟。因此它能代替个人电脑长期运行，但不能保证实时抢到容量。

## 必须配置的 Repository Secrets

在仓库的 **Settings → Secrets and variables → Actions → New repository secret** 中配置：

- `OCI_USER_OCID`
- `OCI_TENANCY_OCID`
- `OCI_FINGERPRINT`
- `OCI_PRIVATE_KEY`：OCI API 私钥，不是 SSH 私钥
- `OCI_REGION`：例如 `mx-queretaro-1`
- `OCI_COMPARTMENT_OCID`
- `OCI_AVAILABILITY_DOMAINS`：每行一个完整 AD 名称
- `OCI_SUBNET_OCID`
- `OCI_IMAGE_OCID`
- `OCI_SSH_PUBLIC_KEY`

不要把这些内容写入代码，也不要把 OCI 私钥提交到仓库。

## 可选 Repository Variables

在 **Settings → Secrets and variables → Actions → Variables** 中配置：

- `OCI_INSTANCE_NAME`：默认 `mmc-node`
- `OCI_AUTO_CREATE`：默认 `false`

## 运行模式

默认定时任务只监控，不创建。这样可以先验证 OCI API 凭据和所有 OCID 是否正确。

如果确认配置正确，并接受实例创建可能带来的账户资源影响，可以把 `OCI_AUTO_CREATE` 设为 `true`。之后每次运行会：

1. 检查是否已经存在同名实例；
2. 按配置的 AD 顺序尝试；
3. 只创建 `VM.Standard.A1.Flex`；
4. 严格使用 `1 OCPU / 1 GB`；
5. 成功后停止后续 AD 尝试。

也可以在 GitHub Actions 页面手动运行 **OCI A1 capacity watcher**，并把 `auto_create` 设为 `true`。

## 结论

它不能保证抢到。它只解决“没有机器 24 小时开机”的问题。实际成功仍取决于：

- Querétaro Home Region 是否释放 A1 容量；
- 配置的 AD 是否可用；
- GitHub 的定时任务是否准时启动；
- OCI 账户配额、Subnet、镜像和 SSH 公钥是否正确。
