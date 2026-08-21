/** @type {import('tailwindcss').Config} */
// Tailwind scans these files for class names and rebuilds wwwroot/app.css. The `.nsx` glob is essential:
// the views live in `.nsx` files, so without it every utility class used only in a view would be dropped
// from the output stylesheet. `.nova` is kept for any classes that appear in plain logic modules, and the
// static shell (index.html) is scanned too. Referenced from styles/app.css via `@config`.
module.exports = {
  content: [
    "./src/**/*.{nsx,nova}",
    "./wwwroot/*.html",
  ],
};
