// Open-in-new-tab handler for mermaid_zoomable shortcode.
// Uses event delegation so the script is safe to load multiple times.
if (!window._mermaidZoomableInit) {
  window._mermaidZoomableInit = true;
  document.addEventListener('click', function (e) {
    var btn = e.target.closest('[data-mermaid-open]');
    if (!btn) return;
    var wrapper = btn.closest('.mermaid-zoomable-wrapper');
    if (!wrapper) return;
    var svg = wrapper.querySelector('svg');
    if (!svg) return;
    var clone = svg.cloneNode(true);
    clone.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
    var data = new XMLSerializer().serializeToString(clone);
    var blob = new Blob([data], { type: 'image/svg+xml;charset=utf-8' });
    var url = URL.createObjectURL(blob);
    window.open(url, '_blank');
  });
}
