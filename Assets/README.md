# App 图标

`AppIcon.icns` 是本项目自绘的静态双屏图标，无外部素材。默认打包直接复制，无需图像生成服务或额外依赖。

需要重新生成图标时：

```sh
mkdir -p .build/icon-module-cache build
swiftc -module-cache-path .build/icon-module-cache scripts/make-icon.swift -o .build/make-icon
.build/make-icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o Assets/AppIcon.icns
```
