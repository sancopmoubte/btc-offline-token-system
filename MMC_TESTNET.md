# 猫猫币 MMC 独立测试链

## 网络

- 网络名称：`MMC-TESTNET`
- Supabase 项目：与生产项目相同，但使用完全独立的测试表和测试 RPC
- 生产区块表：`public.chain_blocks_raw`，不会被测试网写入
- 测试区块表：`public.mmc_test_chain_blocks`
- 测试状态表：`public.mmc_test_chain_state`
- 状态 RPC：`public.get_mmc_testnet_status()`

## 测试预分配

地址：

```text
pqc15e91a92ae40ac6acb449dcd8e079a84ddf2eb1ba
```

测试余额：

```text
21,000,000 MMC
```

分配位于测试网高度 0 的 `test_alloc` 交易中，仅用于测试，不属于生产共识，也不会改变生产链哈希。

## 当前测试网状态

- 高度：`0`
- 测试余额：`21,000,000 MMC`
- 测试创世哈希：`9c0dab35c00d2ef54bf4fae26c88bd5558d8dfdc057f7640289bc4df748fffa6`
- 生产网高度：`0`
- 生产网创世哈希：`3d8d22899a36c78da2aa082360f36ba770db9d312dd1a5c49687fec6287a39ee`

## 重要边界

- 生产页面不会显示测试余额。
- 测试余额不能转入生产网。
- 测试网的 `test_alloc` 不会被生产网页的生产链重放逻辑接受。
- 测试链和生产链可以分别重置；测试链重置不会删除生产区块。
- 该地址的私钥仍不会上传或存储在 Supabase；只有拥有私钥才能在后续测试页面中签名操作。
