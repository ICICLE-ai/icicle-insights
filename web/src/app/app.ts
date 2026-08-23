import { Component, inject } from '@angular/core';
import { RouterOutlet } from '@angular/router';

import { TokenStore } from './core/auth/token-store';

@Component({
  selector: 'app-root',
  imports: [RouterOutlet],
  templateUrl: './app.html',
  styleUrl: './app.css',
})
export class App {
  private readonly tokens = inject(TokenStore);

  constructor() {
    // Runs the token acquisition chain once at startup. Deliberately not awaited and never
    // blocking: reads are public, so the application must render fully for a visitor holding no
    // credential at all, and admin capability is a later enhancement rather than a precondition.
    this.tokens.initialize();
  }
}
