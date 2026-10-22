// Типизирует `exports` из "cloudflare:workers" экспортами src/index.ts.
declare namespace Cloudflare {
  interface GlobalProps {
    mainModule: typeof import("../src/index");
  }
}
