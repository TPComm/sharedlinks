// Imported `with { type: "file" }`: Bun gives the path (embedded in a compiled binary).
declare module "*.png" {
  const path: string;
  export default path;
}
