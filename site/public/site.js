// Names the version /download gets, from the same latest.json Codec reads for updates, and copies
// the install commands.

const release = document.getElementById("release");

fetch("/releases/latest.json", { cache: "no-cache" })
  .then((response) => (response.ok ? response.json() : Promise.reject(response.status)))
  .then((latest) => {
    const version = latest.tag_name.replace(/^v/, "");
    const image = (latest.assets ?? []).find((asset) => asset.name.toLowerCase().endsWith(".dmg"));
    const size = image?.size ? `, ${Math.round(image.size / 1e6)} MB` : "";
    release.textContent = `Codec ${version}${size}. For macOS 26 or later, on Apple silicon or Intel.`;
  })
  .catch(() => {});

for (const button of document.querySelectorAll(".copy")) {
  button.addEventListener("click", async () => {
    const text = button.parentElement.querySelector("code").textContent;
    try {
      await navigator.clipboard.writeText(text);
      button.textContent = "Copied";
    } catch {
      button.textContent = "Select and copy";
    }
    setTimeout(() => (button.textContent = "Copy"), 1800);
  });
}
