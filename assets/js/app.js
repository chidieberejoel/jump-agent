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

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

let Hooks = {}

Hooks.MessageList = {
  mounted() {
    this.scrollToBottom()

    this.observer = new MutationObserver((mutations) => {
      this.scrollToBottom()
    })

    this.observer.observe(this.el, {
      childList: true,
      subtree: true,
      attributes: false,
      characterData: false
    })
  },

  updated() {
    requestAnimationFrame(() => {
      this.scrollToBottom()
    })
  },

  destroyed() {
    if (this.observer) {
      this.observer.disconnect()
    }
  },

  scrollToBottom() {
    const before = this.el.scrollTop
    this.el.scrollTop = this.el.scrollHeight
    const after = this.el.scrollTop

    if (after === before && this.el.scrollHeight > this.el.clientHeight) {
      this.el.scrollTo({
        top: this.el.scrollHeight,
        behavior: 'smooth'
      })
    }
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

