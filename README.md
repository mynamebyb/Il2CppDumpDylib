# Il2CppDumpDylib

注入到 Unity IL2CPP 游戏进程，点悬浮按钮手动 dump 出：
- `global-metadata.dat`（从内存扫 magic 0xFAB11BAF）
- `UnityFramework`（整个模块内存）

产物写到 App 的 `Documents` 目录，用 Sideloadly / iTunes File Sharing 导出。

## 用法
1. GitHub Actions 编译出 `libIl2CppDumpDylib.dylib`
2. Sideloadly 注入到解密 IPA，重签名安装
3. 打开游戏，**等全部资源下载完，进自由漫游**
4. 点屏幕左侧蓝色 `DUMP` 按钮 → 确认
5. 弹"完成"后，用 File Sharing 导出 Documents 里的两个文件
6. 把这两个文件丢电脑跑 Il2CppDumper

## 注意
- 必须等游戏资源全部下完再点，否则 metadata 残缺
- LiveContainer 环境也能用
- 导出后在电脑上：`Il2CppDumper UnityFramework global-metadata.dat outdir`
