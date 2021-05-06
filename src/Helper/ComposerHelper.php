<?php

/**
 * @copyright Copyright (C) Ibexa AS. All rights reserved.
 * @license For full copyright and license information view LICENSE file distributed with this source code.
 */
declare(strict_types=1);

namespace Ibexa\Platform\ContiniousIntegrationScripts\Helper;

class ComposerHelper
{
    public static function getGitHubToken(): ?string
    {
        $output = [];
        $result_code = 0;
        exec('composer config github-oauth.github.com --global 2> /dev/null', $output, $result_code);

        return $result_code === 0 ? $output[0] : null;
    }
}
