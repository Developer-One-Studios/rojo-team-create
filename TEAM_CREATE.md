<div align="center">
    <img src="assets/brand_images/logo-512.png" alt="Rojo Team Create" height="217" />
</div>

# Rojo Team Create

Rojo Team Create is a version of [Rojo](https://github.com/rojo-rbx/rojo) whose Studio plugin works with Team Create. Every collaborator can sync their own local codebase into the same Team Create place without overwriting each other.

## How it works

When you connect in a Team Create place, the plugin **stages** your changes instead of writing them into the DataModel.

- **Staged changes stay on your machine.** They don't replicate to other Team Create users and aren't saved with the place. Other developers syncing their own codebase aren't affected by your changes, and you aren't affected by theirs.
- **Play includes your staged changes.** Press **Play** in the Rojo Team Create panel to start a local playtest that runs your staged code. You can bind keyboard shortcuts to the *Rojo: Play With Staged Changes* and *Rojo: Run With Staged Changes* actions.
- **Deploy applies them for everyone.** Press **Deploy** to write your staged changes into the place. They then save to the place file and replicate to everyone who isn't syncing. They're also used when you publish the game or start a Team Test.

The count at the top right of the panel shows how many instances are staged. Click it to see exactly what would change. The count updates as you edit files, and also when the place changes underneath you, for example when a collaborator deploys.

Studio's own Play button tests the deployed version of the place. If you have staged changes when you use it, Rojo Team Create warns you in the Output window that they aren't included.

Outside of Team Create, the plugin syncs exactly like Rojo.

## Installing

Rojo Team Create only changes the Studio plugin, so it works with a normal Rojo 7.7 server (`rojo serve`).

1. Clone this repository, run `git submodule update --init --recursive`, then build the plugin into your Studio plugins folder:

    ```bash
    rojo build plugin.project.json --plugin RojoTeamCreate.rbxm
    ```

2. Uninstall or disable the regular Rojo plugin. If both are installed, both will try to sync the same project.
3. Run `rojo serve` in your project and press **Connect** in the Rojo Team Create panel.

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| Stage Changes in Team Create | On | Keep synced changes local until you deploy them. Turn this off to sync straight into the place like regular Rojo. |

All of Rojo's other settings are still available.

## Things to know

- **Rojo's Play briefly shares your changes.** Game scripts in a playtest start running before any plugin loads, so a plugin can't swap your code in afterwards. Instead, the plugin writes your staged changes into the place, starts the playtest, and reverts them as soon as the playtest reports back. Collaborators can see your staged changes for those few seconds (about 4–5 seconds in testing).
- **Two-way sync is off while staging.** Otherwise a collaborator's deploy would be written back into your files.
- **The sync lock isn't used while staging.** Several collaborators can be connected at once, since nobody writes to the place until they deploy.
- **Staged changes are recomputed from the whole project** on each change, so very large projects may take a moment to update the staged count.

## License

Rojo Team Create is based on [Rojo](https://github.com/rojo-rbx/rojo) and is available under the terms of the Mozilla Public License, Version 2.0. See [LICENSE.txt](LICENSE.txt) for details.
