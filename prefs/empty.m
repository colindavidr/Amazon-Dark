// Intentionally empty.
//
// This file exists so the preference bundle HAS an executable -- Settings
// refuses to load a bundle without one ("executable couldn't be located") --
// while containing no code of ours that could run.
//
// Every previous pane shipped real code and faulted SIGBUS inside Settings at
// whatever call it reached first: loadSpecifiersFromPlistName in v5.53/58,
// groupSpecifierWithName in v5.55, pathForResource in v5.60. Five unrelated
// implementations, same failure -- our binary executes a few instructions and
// then dies. Notably dlopen ALWAYS succeeded (the ctor logged) -- so a bundle
// whose executable never runs any of our code sidesteps the problem entirely.
//
// NSPrincipalClass is set to Apple's own PSListController, which renders
// Root.plist. Nothing here is ours except the plist.
