# MoltenVK iOS 预编译库放置说明

GN 目标 `//third_party/MoltenVK:moltenvk_ios` 会链接本目录下的 **`libMoltenVK.a`**。

## 仅在有依赖时执行 + 强制重编标记

- **action 始终存在**：产物写在 **out 下 target_gen_dir**，不再依赖源码树里必须先有 `prebuilt/ios/libMoltenVK.a`，避免 ninja “missing and no known rule”。
- **moltenvk_ios_build_enabled = true**：脚本在 MoltenVK 目录执行 `make ios`，把 `Package/` 里的 `libMoltenVK.a` 拷到 gen。
- **moltenvk_ios_build_enabled = false**：脚本只在你已放置好的 **`moltenvk_ios_prebuilt_a`**（默认即本目录 `libMoltenVK.a`）存在时，把它拷进 gen；不存在则 action 失败并打印提示。
- **强制重新编译**：在 `gn args` 里改 `moltenvk_ios_rebuild_stamp`（任意新字符串，如日期），再执行 `gn gen`，下次 `ninja` 会再次执行 `make ios`。

示例：

```gn
# 打开自动构建（有依赖时才执行）
moltenvk_ios_build_enabled = true

# 想强制重编时改掉 stamp 即可
moltenvk_ios_rebuild_stamp = "2025-03-12"
```

## 生成步骤（与上游 MoltenVK 一致）

1. 拉依赖并编译外部库（**须先手动完成**；`build_moltenvk_ios.sh` 不再调用 `fetchDependencies`）：
   ```bash
   cd third_party/MoltenVK
   ./fetchDependencies --ios --iossim
   ```
   离线场景需事先备好完整 `External/` 后再走 GN 构建。
2. 用 Xcode 打开 `MoltenVKPackaging.xcodeproj`，选择 Scheme：
   - **MoltenVK Package (iOS only)**（Release）
3. 编译完成后，在 `Package/Release/`（或 `Package/Debug/`）下查找：
   - `libMoltenVK.a`
   - 若链接报错缺符号，可能还需要同目录的 `libMoltenVKShaderConverter.a`，需一并加入 GN（可再建一个 prebuilt 或合并为单个 xcframework，视你 Xcode 产物而定）。
4. 将 `libMoltenVK.a` **复制到本目录**：
   ```
   third_party/MoltenVK/prebuilt/ios/libMoltenVK.a
   ```

## 自定义路径

若 `.a` 放在其他位置，在 `gn args` 中设置：

```gn
moltenvk_ios_prebuilt_a = "//path/to/your/libMoltenVK.a"
```

## 链接时系统框架

MoltenVK 依赖 Metal 等；在 `ios/BUILD.gn` 里已增加 `Metal.framework` 等，若仍缺符号，按 MoltenVK 文档补充 `Foundation`、`QuartzCore`、`IOSurface` 等。
