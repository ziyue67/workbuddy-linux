# 许可范围说明 / Scope of the license

本仓库的 [MIT 许可证](LICENSE) **只覆盖作者自己创作的部分**，即：

- `install.sh`
- `scripts/update-index.sh`
- `scripts/fix-tls.sh`
- `.github/workflows/update-index.yml`
- `README.md` 与本文档
- `index.json`（接口元数据的整理结果）

## 不覆盖的部分

[WorkBuddy](https://www.workbuddy.cn/) 是腾讯科技（深圳）有限公司的专有软件，版权归腾讯所有。

- 它的二进制安装包（deb / rpm）**不受本仓库的 MIT 许可证约束**，本仓库也**不分发**这些安装包。
- `install.sh` 运行时通过腾讯官方 CDN（`download.codebuddy.cn`）下载安装包，下载与使用须遵守腾讯自己的许可条款。
- 本仓库与腾讯公司没有任何隶属或合作关系，不是官方项目。

## English

The MIT license in this repository covers only the scripts, documentation and
index data authored here. WorkBuddy itself is proprietary software of Tencent
Technology (Shenzhen) Company Limited. Its binary packages are not covered by
this license and are not redistributed by this repository; the installer simply
downloads them from Tencent's own CDN at run time. This project is not
affiliated with Tencent.
