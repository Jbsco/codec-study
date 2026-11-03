--  The version of a build: release.sh writes git describe into its own copy, and the repository's copy says "dev".
package Build_Version is
   Version : constant String := "dev";
end Build_Version;
