# CNinOnlyBlocker

仅允许中国IP的入站连接，其余丢弃；出站连接不限制。

## 使用方法

```bash
git clone https://your-url/CNinOnlyBlocker.git
cd CNinOnlyBlocker
chmod +x install.sh
./install.sh
```

## 配置项（修改 config.sh）

- `ALLOW_PING=true`：允许 ping
- `AUTO_SAVE=true`：自动保存规则到 /etc/iptables/rules.v4
- `CNBLOCK_SOURCE_URL`：中国IP规则脚本来源（已设置为 GitLab 版本）
