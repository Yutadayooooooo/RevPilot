import type { NextConfig } from "next";

const nextConfig: NextConfig = {};

export default nextConfig;

// ローカルの `next dev` でも Cloudflare のバインディング（ASSETS など）を
// 使えるようにするためのフック。@opennextjs/cloudflare が要求する。
import { initOpenNextCloudflareForDev } from "@opennextjs/cloudflare";
initOpenNextCloudflareForDev();
