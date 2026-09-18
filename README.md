# 普希达一键安装

仓库只放安装脚本。完整版 / 精简版二进制包约 145MB，超过 GitHub 普通文件 100MB 限制，必须作为 **Release 附件** 上传，不要 `git add *.tar.gz`。

## 其它服务器一键安装（x86_64 Linux，root）

完整版（主控）：

```bash
curl -fsSL https://raw.githubusercontent.com/y648394245-tech/puxida/main/install-full.sh | bash
```

精简版（子节点）：

```bash
curl -fsSL https://raw.githubusercontent.com/y648394245-tech/puxida/main/install-concise.sh | bash
```

指定端口和账号（不要用默认弱口令）：

```bash
curl -fsSL https://raw.githubusercontent.com/y648394245-tech/puxida/main/install-full.sh | \
  bash -s -- --port 41275 --username admin --password '你的强密码'
```

脚本会从本仓库最新 Release 下载：

- `pxd-full-father.tar.gz`
- `pxd-concise-son.tar.gz`

## 发布新版本（本机构建机上）

1. 只推送脚本到 `main`（本目录这几个文件）。
2. 创建 Release，把 `/opt` 里两个 tar 当附件上传。

```bash
# 在已登录 gh 的机器上
cd /root/copy_code/puxida-github
git add README.md LICENSE .gitignore install-full.sh install-concise.sh
git commit -m "Add GitHub one-click installers"
git branch -M main
git remote add origin https://github.com/y648394245-tech/puxida.git
git push -u origin main

gh release create v20260918 \
  /opt/pxd_full_father/pxd-full-father.tar.gz \
  /opt/pxd_concise_son/pxd-concise-son.tar.gz \
  --title "puxida v20260918" \
  --notes "完整版 + 精简版一键安装包"
```

网页操作等价步骤：仓库 → Releases → Draft a new release → 上传两个 `.tar.gz` → Publish。
