// deploy/deploy.sh compiles the git commit in with `--define LINKS_COMMIT='"<sha>"'`; anything else is "dev".
declare const LINKS_COMMIT: string;

/** The git commit this server was built from, as served on /version. */
export const BUILD_COMMIT: string = typeof LINKS_COMMIT === "string" ? LINKS_COMMIT : "dev";
