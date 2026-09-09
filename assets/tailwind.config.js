// Mirrors the theme the app previously configured for the Tailwind CDN
// runtime, so compiled output matches the classes templates already use.
module.exports = {
  content: [
    "./js/**/*.js",
    "../lib/maraithon_web/**/*.{ex,heex}"
  ],
  theme: {
    extend: {
      fontSize: { xs: ["var(--text-ui-sm)", "1.4"], sm: ["var(--text-ui-base)", "1.45"], base: ["var(--text-ui-md)", "1.5"], lg: ["var(--text-ui-lg)", "1.4"] },
      fontFamily: {
        sans: ["Geist", "ui-sans-serif", "system-ui", "sans-serif"],
        display: ['"Instrument Serif"', "ui-serif", "Georgia", "serif"]
      },
      colors: {
        white: "rgb(var(--runner-white) / <alpha-value>)",
        zinc: Object.fromEntries([50,100,200,300,400,500,600,700,800,900,950].map(n => [n, `rgb(var(--runner-zinc-${n}) / <alpha-value>)`])),
        clay: {500: "#a86448", 600: "#965638"},
        olive: {
          50: "oklch(98.8% 0.003 106.5)",
          100: "oklch(96.6% 0.005 106.5)",
          200: "oklch(93% 0.007 106.5)",
          300: "oklch(88% 0.011 106.6)",
          400: "oklch(73.7% 0.021 106.9)",
          500: "oklch(58% 0.031 107.3)",
          600: "oklch(46.6% 0.025 107.3)",
          700: "oklch(39.4% 0.023 107.4)",
          800: "oklch(28.6% 0.016 107.4)",
          900: "oklch(22.8% 0.013 107.4)",
          950: "oklch(15.3% 0.006 107.1)"
        }
      }
    }
  },
  plugins: []
}
