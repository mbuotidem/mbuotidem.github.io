(function() {
    'use strict';

    const STORAGE_KEY = 'mobileBrowseExpanded';
    const toggle = document.getElementById('mobileBrowseToggle');
    const content = document.getElementById('mobileBrowseContent');

    if (!toggle || !content) return;

    // Check localStorage for saved preference (default to collapsed)
    const isExpanded = localStorage.getItem(STORAGE_KEY) === 'true';

    // Set initial state
    function setExpanded(expanded) {
        if (expanded) {
            content.classList.add('expanded');
            toggle.setAttribute('aria-expanded', 'true');
        } else {
            content.classList.remove('expanded');
            toggle.setAttribute('aria-expanded', 'false');
        }
        localStorage.setItem(STORAGE_KEY, expanded);
    }

    // Initialize with saved state
    setExpanded(isExpanded);

    // Toggle on click
    toggle.addEventListener('click', function() {
        const expanded = toggle.getAttribute('aria-expanded') === 'true';
        setExpanded(!expanded);
    });
})();
