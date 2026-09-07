document.addEventListener("turbolinks:load", function () {
  if (document.querySelectorAll("meta[name='push_notifications']").length > 0) {
    var arrived = 0;
    var banner = document.querySelector('.js-new-notifications');

    // A new notification is announced rather than pushed as a row: the list is
    // filtered, sorted and paginated server-side, so only a reload can tell
    // whether it belongs on the page currently being viewed.
    var announceArrival = function() {
      if (!banner) return;

      arrived += 1;
      var count = banner.querySelector('.js-new-notifications-count');
      if (count) {
        count.textContent = (arrived === 1)
          ? '1 new notification. Click to refresh.'
          : arrived + ' new notifications. Click to refresh.';
      }
      banner.classList.remove('d-none');
    };

    if (banner) {
      banner.addEventListener('click', function(e) {
        var link = e.target.closest('.js-new-notifications-refresh');
        if (!link) return;
        e.preventDefault();
        Turbolinks.visit("/" + location.search);
      });
    }

    App.notifications = App.cable.subscriptions.create("NotificationsChannel", {
      received: function(data) {
        if (data.arrived) {
          announceArrival();
          return;
        }

        var el = '#notification-'+data.id;
        if(document.querySelectorAll(el).length) {
          var selected = document.querySelector(el).querySelector("input:checked");
          document.querySelector(el).outerHTML = data.notification;
          if (selected) {
            document.querySelector(el).querySelector("input[type=checkbox]").checked = true;
          }
        }
        var thread = document.querySelector('#notification-thread');
        if(thread && thread.getAttribute('data-id') == data.id){
          document.querySelector('#thread-subject').innerHTML = data.subject;
        }

        Octobox.updateAllPinnedSearchCounts();
      }
    });
  }
});
