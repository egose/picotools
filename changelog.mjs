// See https://github.com/conventional-changelog/conventional-changelog/tree/master/packages/conventional-changelog#js-api
// See https://github.com/conventional-changelog/conventional-changelog/tree/master/packages/conventional-changelog-conventionalcommits
import { createWriteStream } from "node:fs";
import createPreset from "conventional-changelog-conventionalcommits";
import { ConventionalChangelog } from "conventional-changelog";

const generator = new ConventionalChangelog();

const myPreset = await createPreset({
  types: [
    {
      type: "feat",
      section: "Features",
    },
    {
      type: "fix",
      scope: "deps",
      hidden: true,
    },
    {
      type: "fix",
      section: "Bug Fixes",
    },
    {
      type: "docs",
      section: "Docs",
    },
    {
      type: "refactor",
      section: "Refactors",
    },
    {
      type: "e2e",
      section: "End-to-end Testing",
    },
    {
      type: "chore",
      hidden: true,
    },
    {
      type: "style",
      hidden: true,
    },
    {
      type: "perf",
      hidden: true,
    },
    {
      type: "test",
      hidden: true,
    },
  ],
});

myPreset.name = "conventionalcommits";
generator
  .readPackage()
  .loadPreset(myPreset)
  .options({
    append: false,
    releaseCount: 0,
    skipUnstable: true,
    outputUnreleased: true,
    tagPrefix: "v",
    firstRelease: false,
  })
  .config({
    tags: myPreset.tags,
    commits: myPreset.commits,
    parser: myPreset.parser,
    writer: myPreset.writer,
  });

const fileStream = createWriteStream("CHANGELOG.md");

generator.writeStream().pipe(fileStream);

fileStream.on("finish", () => {
  console.log("Changelog generated.");
});
