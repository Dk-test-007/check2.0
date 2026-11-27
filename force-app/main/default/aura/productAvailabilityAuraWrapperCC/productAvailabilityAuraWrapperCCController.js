({
    doInit: function(component, event) {
        var attempts = 0;
        var maxAttempts = 20;

        var maximizeInterval = window.setInterval(function() {
            attempts++;

            var maximizeButton = document.querySelector(
                'button[title="Maximize"], button[aria-label="Maximize"]'
            );

            if (maximizeButton) {
                window.clearInterval(maximizeInterval);
                maximizeButton.click();

                window.setTimeout(function() {
                    var modal = document.querySelector(
                        '.slds-modal.slds-fade-in-open .slds-modal__container'
                    );

                    if (modal) {
                        modal.style.width = '90vw';
                        modal.style.maxWidth = '1200px';
                        modal.style.minWidth = '0';
                    }

                    var modalContent = document.querySelector(
                        '.slds-modal.slds-fade-in-open .slds-modal__content'
                    );

                    if (modalContent) {
                        modalContent.style.height = '80vh';
                        modalContent.style.maxHeight = '80vh';
                        modalContent.style.minHeight = '300px';
                        modalContent.style.overflowY = 'auto';
                    }
                }, 300);
            } else if (attempts >= maxAttempts) {
                window.clearInterval(maximizeInterval);
            }
        }, 200);
    }
})