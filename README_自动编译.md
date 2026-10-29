# Tinge18 RootHide：在线自动编译工程（实验性）

这个 ZIP 不是 .deb，也没有通过编译或 iOS 18.3 实机测试，不能直接在 Sileo 安装。

这份工程为无法在本地安装 Xcode / Theos 的用户准备了 GitHub Actions 自动编译任务。
若能够成功构建，Actions 会生成一个 artifact，内含 .deb；但生成 .deb 不等于适配成功，也不保证稳定运行。

步骤：
1. 用 GitHub 帐号创建空仓库（不要添加初始 README）。
2. 解压 ZIP，将压缩包**内部**所有文件及 `.github/workflows/build.yml` 上传到仓库根目录。
   注意：部分手机解压软件会隐藏以点开头的 `.github` 目录。它必须被上传。
3. 进入仓库的 Actions，选中 `Tinge18 RootHide auto build (EXPERIMENTAL)`，点击 `Run workflow`。
4. 如果运行成功，在页面末尾 Artifacts 下载 `Tinge18-RootHide-experimental-deb`。若失败，Actions 的红色编译日志会说明问题，需要开发者继续修复，不能自行假定已完成。

重要：这套流程仅自动编译，**不会**修复任何尚未发现的 SpringBoard 私有 API 变化。安装前务必先卸载冲突角标插件，确认能进入 Safe Mode / 禁用插件，并备份布局。用户此前已遇到 SpringBoard 崩溃，因此不建议在主力机上直接安装一个未测试的实验包。

源码说明见 BUILD_AND_SAFETY.md。源代码里不包含 Tinge 26 旧核心。此工程属于新的实验性精简实现。
