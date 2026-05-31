// scripts/before-build.cjs —— electron-builder 打包前按目标 arch 重建原生 addon
const { execFileSync } = require("node:child_process");
const path = require("node:path");

// electron-builder Arch 枚举: ia32=0, x64=1, armv7l=2, arm64=3, universal=4
const ARCH_NAME = { 0: "ia32", 1: "x64", 2: "armv7l", 3: "arm64", 4: "universal" };

module.exports = async function beforeBuild(context) {
  if (process.platform !== "darwin") return true;
  const archName = ARCH_NAME[context.arch] || process.arch;
  console.log(`[before-build] rebuilding native addon for arch ${archName}`);
  execFileSync("node", [path.join(__dirname, "build-native.mjs")], {
    stdio: "inherit",
    env: { ...process.env, NATIVE_ARCH: archName },
  });
  return true; // 继续 electron-builder 默认流程
};
