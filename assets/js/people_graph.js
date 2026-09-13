// Bounded 2D explorer. Layout runs only when the visible node set changes;
// panning, zooming and selection never request source data or recompute ranks.
export const PeopleGraph = {
  mounted() {
    this.area = this.el.querySelector('[data-graph-area]')
    this.canvas = this.area.querySelector('canvas')
    this.buttons = this.area.querySelector('[data-graph-nodes]')
    this.camera = {x: 0, y: 0, zoom: 1}
    this.positions = new Map()
    this.pointers = new Map()
    this.cleanups = []
    const listen = (el, type, fn, opts) => {
      el.addEventListener(type, fn, opts)
      this.cleanups.push(() => el.removeEventListener(type, fn, opts))
    }
    listen(this.el, 'click', event => {
      const action = event.target.closest('[data-graph-action]')?.dataset.graphAction
      if (action === 'fit') this.camera = {x: 0, y: 0, zoom: 1}
      if (action === 'zoom-in') this.camera.zoom = Math.min(4, this.camera.zoom * 1.25)
      if (action === 'zoom-out') this.camera.zoom = Math.max(.4, this.camera.zoom / 1.25)
      if (action) this.draw()
    })
    listen(this.area, 'pointerdown', event => this.pointerDown(event))
    listen(this.area, 'pointermove', event => this.pointerMove(event))
    listen(this.area, 'pointerup', event => this.pointerUp(event))
    listen(this.area, 'pointercancel', event => { this.pointers.delete(event.pointerId); this.drag = null })
    listen(this.area, 'wheel', event => {
      if (!event.ctrlKey && !event.metaKey) return
      event.preventDefault()
      this.camera.zoom = Math.max(.4, Math.min(4, this.camera.zoom * Math.exp(-event.deltaY * .005)))
      this.draw()
    }, {passive: false})
    this.observer = new ResizeObserver(() => this.draw())
    this.observer.observe(this.area)
    this.updateData()
  },
  updated() { this.updateData() },
  destroyed() {
    this.observer.disconnect()
    this.cleanups.forEach(cleanup => cleanup())
    if (this.frame) cancelAnimationFrame(this.frame)
  },
  updateData() {
    this.data = JSON.parse(this.el.dataset.graph)
    const signature = this.data.nodes.map(node => `${node.id}:${node.x}:${node.y}`).join('|')
    if (signature !== this.signature) {
      this.signature = signature
      this.layout()
      this.renderButtons()
    }
    this.draw()
  },
  layout() {
    const nodes = [{id: 'you', x: 0, y: 0, rank: 100}, ...this.data.nodes]
    const positions = new Map(nodes.map(node => [node.id, this.positions.get(node.id) || {x: node.x, y: node.y}]))
    // Static collision relaxation over at most 85 visible people. There is no
    // perpetual animation or all-contact graph computation in the browser.
    for (let iteration = 0; iteration < 40; iteration++) {
      for (let i = 0; i < nodes.length; i++) {
        for (let j = i + 1; j < nodes.length; j++) {
          const a = positions.get(nodes[i].id), b = positions.get(nodes[j].id)
          const dx = b.x - a.x || .001, dy = b.y - a.y || .001
          const distance = Math.hypot(dx, dy)
          if (distance > .17) continue
          const push = (.17 - distance) * .2
          if (nodes[i].id !== 'you') { a.x -= dx / distance * push; a.y -= dy / distance * push }
          if (nodes[j].id !== 'you') { b.x += dx / distance * push; b.y += dy / distance * push }
        }
      }
    }
    this.positions = positions
  },
  renderButtons() {
    this.buttons.replaceChildren()
    const nodes = [{id: 'you', name: 'You', rank: 100}, ...this.data.nodes]
    nodes.forEach((node, index) => {
      const button = document.createElement('button')
      button.type = 'button'
      button.dataset.nodeId = node.id
      button.className = 'absolute flex items-center justify-center rounded-full border border-zinc-300 bg-white text-xs font-medium text-zinc-700 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-blue-600'
      button.style.transform = 'translate(-50%, -50%)'
      button.style.touchAction = 'none'
      const size = node.id === 'you' ? 42 : 26 + Math.sqrt(node.rank || 0) * 1.6
      button.style.width = `${size}px`
      button.style.height = `${size}px`
      button.textContent = node.id === 'you' ? 'You' : node.name.split(/\s+/).filter(Boolean).slice(0, 2).map(part => [...part][0]).join('').toUpperCase()
      button.setAttribute('aria-label', `${node.name}${node.id === 'you' ? '' : `, ${node.active_days} active days. Open person.`}`)
      button.title = node.name
      button.addEventListener('click', event => {
        if (this.suppressClick && event.detail !== 0) { event.preventDefault(); return }
        if (node.id !== 'you') this.pushEvent('select_person', {id: node.id})
      })
      const label = document.createElement('span')
      label.className = 'pointer-events-none absolute left-1/2 top-full mt-1 max-w-32 -translate-x-1/2 whitespace-nowrap rounded bg-white/90 px-1 text-xs font-medium text-zinc-700'
      label.textContent = node.name
      label.dataset.nodeLabel = node.id
      label.hidden = index > 12
      button.append(label)
      this.buttons.append(button)
    })
  },
  screen(position) {
    const scale = Math.min(this.width, this.height) * .39 * this.camera.zoom
    return {x: this.width / 2 + this.camera.x + position.x * scale,
      y: this.height / 2 + this.camera.y + position.y * scale}
  },
  draw() {
    if (this.frame) return
    this.frame = requestAnimationFrame(() => {
      this.frame = null
      this.width = this.area.clientWidth
      this.height = this.area.clientHeight
      if (!this.width || !this.height || !this.data) return
      const ratio = window.devicePixelRatio || 1
      this.canvas.width = this.width * ratio
      this.canvas.height = this.height * ratio
      const ctx = this.canvas.getContext('2d')
      ctx.scale(ratio, ratio)
      this.data.edges.forEach(edge => {
        const a = this.positions.get(edge.from), b = this.positions.get(edge.to)
        if (!a || !b) return
        const from = this.screen(a), to = this.screen(b)
        const active = edge.from === this.data.selected || edge.to === this.data.selected
        ctx.strokeStyle = active ? '#3b82f6' : '#a1a1aa'
        ctx.globalAlpha = active ? .75 : .35
        ctx.lineWidth = edge.kind === 'direct' ? Math.min(3, .7 + Math.log1p(edge.weight)) : 1
        ctx.setLineDash(edge.kind === 'shared' ? [4, 5] : [])
        ctx.beginPath(); ctx.moveTo(from.x, from.y); ctx.lineTo(to.x, to.y); ctx.stroke()
      })
      ctx.globalAlpha = 1
      this.buttons.querySelectorAll('[data-node-id]').forEach(button => {
        const id = button.dataset.nodeId, selected = id === this.data.selected
        const position = this.screen(this.positions.get(id))
        button.style.left = `${position.x}px`
        button.style.top = `${position.y}px`
        button.style.zIndex = selected ? '3' : id === 'you' ? '2' : '1'
        button.style.borderColor = selected ? '#2563eb' : ''
        button.style.backgroundColor = selected ? '#eff6ff' : ''
        button.setAttribute('aria-pressed', String(selected))
        const index = this.data.nodes.findIndex(node => node.id === id)
        button.querySelector('[data-node-label]').hidden = id === 'you' || (!selected && index > 11 && this.camera.zoom < 1.7)
      })
    })
  },
  pointerDown(event) {
    const point = {x: event.clientX, y: event.clientY}
    this.pointers.set(event.pointerId, point)
    this.suppressClick = false
    const id = event.target.closest('[data-node-id]')?.dataset.nodeId
    this.drag = {id, x: point.x, y: point.y, moved: false}
    if (this.pointers.size === 2) this.pinch = this.pointerDistance()
    const captureTarget = event.target.closest('[data-node-id]') || this.area
    captureTarget.setPointerCapture(event.pointerId)
  },
  pointerMove(event) {
    if (!this.pointers.has(event.pointerId) || !this.drag) return
    const old = this.pointers.get(event.pointerId)
    this.pointers.set(event.pointerId, {x: event.clientX, y: event.clientY})
    const dx = event.clientX - old.x, dy = event.clientY - old.y
    if (Math.hypot(event.clientX - this.drag.x, event.clientY - this.drag.y) > 4) this.drag.moved = true
    if (!this.drag.moved) return
    if (this.pointers.size === 2) {
      const distance = this.pointerDistance()
      if (this.pinch) this.camera.zoom = Math.max(.4, Math.min(4, this.camera.zoom * distance / this.pinch))
      this.pinch = distance
    } else if (this.drag.id && this.drag.id !== 'you') {
      const position = this.positions.get(this.drag.id)
      const scale = Math.min(this.width, this.height) * .39 * this.camera.zoom
      position.x += dx / scale; position.y += dy / scale
    } else { this.camera.x += dx; this.camera.y += dy }
    this.draw()
  },
  pointerUp(event) {
    this.pointers.delete(event.pointerId)
    if (!this.drag) return
    this.suppressClick = this.drag.moved
    if (!this.drag.id && !this.drag.moved) this.selectEdge(event)
    this.drag = null
    if (this.pointers.size < 2) this.pinch = null
  },
  pointerDistance() {
    const [a, b] = [...this.pointers.values()]
    return a && b ? Math.hypot(a.x - b.x, a.y - b.y) : 0
  },
  selectEdge(event) {
    const rect = this.area.getBoundingClientRect(), point = {x: event.clientX - rect.left, y: event.clientY - rect.top}
    let best = null, nearest = 8
    this.data.edges.forEach(edge => {
      const start = this.positions.get(edge.from), end = this.positions.get(edge.to)
      if (!start || !end) return
      const a = this.screen(start), b = this.screen(end)
      const dx = b.x - a.x, dy = b.y - a.y
      const t = Math.max(0, Math.min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / (dx * dx + dy * dy || 1)))
      const distance = Math.hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
      if (distance < nearest) { best = edge; nearest = distance }
    })
    if (best) this.pushEvent('select_connection', {id: best.id})
  }
}

export const PeopleDates = {
  mounted() { this.formatDates() },
  updated() { this.formatDates() },
  formatDates() {
    const formatter = new Intl.DateTimeFormat(undefined, {month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit'})
    this.el.querySelectorAll('time[datetime]').forEach(element => {
      const date = new Date(element.dateTime)
      if (!Number.isNaN(date.valueOf())) element.textContent = formatter.format(date)
    })
  }
}
