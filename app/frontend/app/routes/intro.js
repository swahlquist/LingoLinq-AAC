import Route from '@ember/routing/route';
import app_state from '../utils/app_state';

export default Route.extend({
  beforeModel: function() {
    app_state.set('show_intro', true);
    app_state.return_to_index();
  }
});
