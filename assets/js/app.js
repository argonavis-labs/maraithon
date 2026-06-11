import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/maraithon"

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content")

const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks}
})

// Show the slim top progress bar only when navigation takes noticeable time.
let loadingTimeout

window.addEventListener("phx:page-loading-start", () => {
  clearTimeout(loadingTimeout)
  loadingTimeout = setTimeout(() => {
    document.documentElement.classList.add("phx-page-loading")
  }, 120)
})

window.addEventListener("phx:page-loading-stop", () => {
  clearTimeout(loadingTimeout)
  document.documentElement.classList.remove("phx-page-loading")
})

liveSocket.connect()
window.liveSocket = liveSocket

if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("/sw.js", {scope: "/"}).catch(() => {})
  })
}
