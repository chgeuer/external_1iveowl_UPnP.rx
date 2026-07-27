// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/upnp_explorer"
import topbar from "../vendor/topbar"
import {TauriHook} from "../vendor/ex_tauri"

const tauriWebview = window.__TAURI__?.webview

if (tauriWebview) {
  const webview = tauriWebview.getCurrentWebview()
  const minZoom = 0.5
  const maxZoom = 3
  const zoomStep = 0.1
  const storageKey = "upnp-explorer-desktop-zoom"
  const clampZoom = zoom => Math.min(maxZoom, Math.max(minZoom, Math.round(zoom * 10) / 10))
  const storedZoom = Number.parseFloat(window.sessionStorage.getItem(storageKey) || "1")
  let currentZoom = Number.isFinite(storedZoom) ? clampZoom(storedZoom) : 1
  let zoomQueue = Promise.resolve()

  const applyZoom = zoom => {
    const nextZoom = clampZoom(zoom)
    currentZoom = nextZoom
    window.sessionStorage.setItem(storageKey, nextZoom.toString())
    zoomQueue = zoomQueue
      .then(() => webview.setZoom(nextZoom))
      .catch(error => console.error("Failed to set desktop zoom", error))
  }

  window.addEventListener("keydown", event => {
    if (!(event.ctrlKey || event.metaKey)) return

    let nextZoom
    if (["+", "="].includes(event.key) || ["Equal", "NumpadAdd"].includes(event.code)) {
      nextZoom = currentZoom + zoomStep
    } else if (event.key === "-" || ["Minus", "NumpadSubtract"].includes(event.code)) {
      nextZoom = currentZoom - zoomStep
    } else if (event.key === "0" || ["Digit0", "Numpad0"].includes(event.code)) {
      nextZoom = 1
    } else {
      return
    }

    event.preventDefault()
    event.stopPropagation()
    applyZoom(nextZoom)
  })

  window.addEventListener("wheel", event => {
    if (!(event.ctrlKey || event.metaKey) || event.deltaY === 0) return

    event.preventDefault()
    event.stopPropagation()
    applyZoom(currentZoom + (event.deltaY < 0 ? zoomStep : -zoomStep))
  }, {passive: false})

  applyZoom(currentZoom)
}

const systemTheme = window.matchMedia("(prefers-color-scheme: dark)")

const setTheme = source => {
  const theme = source === "system" ? (systemTheme.matches ? "dark" : "light") : source
  document.documentElement.dataset.theme = theme
  document.documentElement.dataset.themeSource = source

  if (source === "system") {
    window.localStorage.removeItem("upnp-explorer-theme")
  } else {
    window.localStorage.setItem("upnp-explorer-theme", source)
  }
}

setTheme(window.localStorage.getItem("upnp-explorer-theme") || "system")

window.addEventListener("phx:set-theme", event => {
  setTheme(event.target.dataset.phxTheme)
})

systemTheme.addEventListener("change", () => {
  if (document.documentElement.dataset.themeSource === "system") setTheme("system")
})

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {TauriHook, ...colocatedHooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#0787a3"}, shadowColor: "transparent"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
