#!/bin/bash

# 是否允许 ping（icmp）
ALLOW_PING=true

# 是否自动保存规则
AUTO_SAVE=true

# 是否清空现有规则
FLUSH_EXISTING=true

# 是否允许本地回环
ALLOW_LOOPBACK=true

# 来源脚本（默认使用你提供的 gitlab cnblock.sh 脚本）
CNBLOCK_SOURCE_URL="https://gitlab.com/gitlabvps1/cnipblocker/-/raw/main/cnblock.sh"
