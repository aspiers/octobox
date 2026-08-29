var CommandPalette = (function() {
  var commands = [];
  var visibleCommands = [];
  var selectedIndex = 0;
  var initialized = false;

  var modalElement = function() {
    return document.querySelector("#command-palette");
  };

  var inputElement = function() {
    return document.querySelector("#command-palette-input");
  };

  var resultsElement = function() {
    return document.querySelector("#command-palette-results");
  };

  var statusElement = function() {
    return document.querySelector("#command-palette-status");
  };

  var isTypingTarget = function(target) {
    return target.matches && target.matches("input, textarea, select, [contenteditable='true']");
  };

  var commandLabel = function(link) {
    var repository = link.classList.contains("repo-label") && link.closest("[title]");
    if (repository) return repository.title;

    var copy = link.cloneNode(true);
    copy.querySelectorAll(".badge").forEach(function(badge) {
      badge.remove();
    });
    return copy.textContent.replace(/\s+/g, " ").trim();
  };

  var sidebarCommands = function() {
    return Array.from(document.querySelectorAll(".flex-sidebar a.nav-link")).map(function(link, position) {
      return { label: commandLabel(link), link: link, position: position };
    }).filter(function(command) {
      return command.label.length > 0;
    });
  };

  var clearResults = function(results) {
    while (results.firstChild) results.removeChild(results.firstChild);
  };

  var render = function(query) {
    var results = resultsElement();
    if (!results) return;

    var normalizedQuery = query.trim().toLowerCase();
    visibleCommands = commands.filter(function(command) {
      return command.label.toLowerCase().includes(normalizedQuery);
    }).sort(function(left, right) {
      var leftIsPrefix = left.label.toLowerCase().startsWith(normalizedQuery);
      var rightIsPrefix = right.label.toLowerCase().startsWith(normalizedQuery);
      if (leftIsPrefix !== rightIsPrefix) return leftIsPrefix ? -1 : 1;
      return left.position - right.position;
    });
    selectedIndex = 0;
    clearResults(results);

    var status = statusElement();
    if (status) {
      status.textContent = visibleCommands.length === 1 ? "1 sidebar item" : visibleCommands.length + " sidebar items";
    }

    if (visibleCommands.length === 0) {
      var empty = document.createElement("div");
      empty.className = "command-palette-empty text-muted";
      empty.textContent = "No matching sidebar items";
      results.append(empty);
      updateSelection();
      return;
    }

    visibleCommands.forEach(function(command, index) {
      var item = document.createElement("button");
      item.type = "button";
      item.id = "command-palette-option-" + index;
      item.className = "command-palette-item list-group-item list-group-item-action";
      item.setAttribute("role", "option");
      item.dataset.index = index;
      item.textContent = command.label;
      results.append(item);
    });
    updateSelection();
  };

  var updateSelection = function() {
    var input = inputElement();
    if (input) input.removeAttribute("aria-activedescendant");

    document.querySelectorAll(".command-palette-item").forEach(function(item, index) {
      var selected = index === selectedIndex;
      item.classList.toggle("active", selected);
      item.setAttribute("aria-selected", selected.toString());
      if (selected) {
        if (input) input.setAttribute("aria-activedescendant", item.id);
        item.scrollIntoView({ block: "nearest" });
      }
    });
  };

  var moveSelection = function(offset) {
    if (visibleCommands.length === 0) return;
    selectedIndex = (selectedIndex + offset + visibleCommands.length) % visibleCommands.length;
    updateSelection();
  };

  var activate = function(index) {
    var command = visibleCommands[index];
    if (!command) return;

    $("#command-palette").one("hidden.bs.modal", function() {
      command.link.click();
    }).modal("hide");
  };

  var open = function(event) {
    if (!modalElement() || document.querySelector(".modal.show")) return;
    if (event) event.preventDefault();

    commands = sidebarCommands();
    render("");
    var input = inputElement();
    if (input) input.value = "";

    $("#command-palette")
      .one("shown.bs.modal", function() {
        var currentInput = inputElement();
        if (currentInput) {
          currentInput.setAttribute("aria-expanded", "true");
          currentInput.focus();
        }
      })
      .one("hidden.bs.modal", function() {
        var currentInput = inputElement();
        if (currentInput) {
          currentInput.setAttribute("aria-expanded", "false");
          currentInput.removeAttribute("aria-activedescendant");
        }
      })
      .modal({ keyboard: false });
  };

  var handleKeydown = function(event) {
    var paletteOpen = modalElement() && modalElement().classList.contains("show");
    if (paletteOpen && event.key === "ArrowDown") {
      event.preventDefault();
      moveSelection(1);
      return;
    } else if (paletteOpen && event.key === "ArrowUp") {
      event.preventDefault();
      moveSelection(-1);
      return;
    } else if (paletteOpen && event.key === "Enter") {
      event.preventDefault();
      activate(selectedIndex);
      return;
    } else if (paletteOpen && event.key === "Escape") {
      event.preventDefault();
      $("#command-palette").modal("hide");
      return;
    }

    var commandKey = (event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k";
    var prefixKey = !event.metaKey && !event.ctrlKey && !event.altKey && event.key.toLowerCase() === "g";
    if (commandKey || (prefixKey && !isTypingTarget(event.target))) open(event);
  };

  var removeBeforeCache = function() {
    var palette = modalElement();
    if (!palette) return;

    if (palette.classList.contains("show")) $(palette).modal("hide");
    $(palette).modal("dispose");
  };

  var initialize = function() {
    if (initialized) return;
    initialized = true;

    document.addEventListener("keydown", handleKeydown);
    document.addEventListener("input", function(event) {
      if (event.target.matches("#command-palette-input")) render(event.target.value);
    });
    document.addEventListener("click", function(event) {
      var item = event.target.closest(".command-palette-item");
      if (item) activate(parseInt(item.dataset.index, 10));
    });
    document.addEventListener("focusin", function(event) {
      var item = event.target.closest(".command-palette-item");
      if (item) {
        selectedIndex = parseInt(item.dataset.index, 10);
        updateSelection();
      }
    });
    document.addEventListener("turbolinks:before-cache", removeBeforeCache);
  };

  return { initialize: initialize };
})();

document.addEventListener("turbolinks:load", CommandPalette.initialize);
